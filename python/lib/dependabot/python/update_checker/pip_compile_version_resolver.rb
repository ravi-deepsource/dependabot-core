# frozen_string_literal: true

require "open3"
require "dependabot/dependency"
require "dependabot/python/requirement_parser"
require "dependabot/python/file_fetcher"
require "dependabot/python/file_parser"
require "dependabot/python/file_parser/python_requirement_parser"
require "dependabot/python/update_checker"
require "dependabot/python/file_updater/requirement_replacer"
require "dependabot/python/file_updater/setup_file_sanitizer"
require "dependabot/python/version"
require "dependabot/shared_helpers"
require "dependabot/python/native_helpers"
require "dependabot/python/python_versions"
require "dependabot/python/name_normaliser"
require "dependabot/python/authed_url_builder"

module Dependabot
  module Python
    class UpdateChecker
      # This class does version resolution for pip-compile. Its approach is:
      # - Unlock the dependency we're checking in the requirements.in file
      # - Run `pip-compile` and see what the result is
      # rubocop:disable Metrics/ClassLength
      class PipCompileVersionResolver
        GIT_DEPENDENCY_UNREACHABLE_REGEX =
          /git clone -q (?<url>[^\s]+).* /.freeze
        GIT_REFERENCE_NOT_FOUND_REGEX =
          %r{git checkout -q (?<tag>[^\n"]+)\n?[^\n]*/(?<name>.*?)(\\n'\]|$)}m.
          freeze

        attr_reader :dependency, :dependency_files, :credentials

        def initialize(dependency:, dependency_files:, credentials:)
          @dependency               = dependency
          @dependency_files         = dependency_files
          @credentials              = credentials
        end

        def latest_resolvable_version(requirement: nil)
          version_string =
            fetch_latest_resolvable_version_string(requirement: requirement)

          version_string.nil? ? nil : Python::Version.new(version_string)
        end

        def resolvable?(version:)
          @resolvable ||= {}
          return @resolvable[version] if @resolvable.key?(version)

          if fetch_latest_resolvable_version_string(requirement: "==#{version}")
            @resolvable[version] = true
          else
            @resolvable[version] = false
          end
        end

        private

        def fetch_latest_resolvable_version_string(requirement:)
          @latest_resolvable_version_string ||= {}
          if @latest_resolvable_version_string.key?(requirement)
            return @latest_resolvable_version_string[requirement]
          end

          @latest_resolvable_version_string[requirement] ||=
            SharedHelpers.in_a_temporary_directory do
              SharedHelpers.with_git_configured(credentials: credentials) do
                write_temporary_dependency_files(updated_req: requirement)
                install_required_python

                filenames_to_compile.each do |filename|
                  # Shell out to pip-compile.
                  # This is slow, as pip-compile needs to do installs.
                  run_pip_compile_command(
                    "pyenv exec pip-compile --allow-unsafe "\
                     "#{pip_compile_options(filename)} -P #{dependency.name} "\
                     "#{filename}"
                  )
                  # Run pip-compile a second time, without an update argument,
                  # to ensure it handles markers correctly
                  write_original_manifest_files unless dependency.top_level?
                  run_pip_compile_command(
                    "pyenv exec pip-compile --allow-unsafe "\
                     "#{pip_compile_options(filename)} #{filename}"
                  )
                end

                # Remove any .python-version file before parsing the reqs
                FileUtils.remove_entry(".python-version", true)

                parse_updated_files
              end
            rescue SharedHelpers::HelperSubprocessFailed => e
              handle_pip_compile_errors(e)
            end
        end

        # rubocop:disable Metrics/AbcSize
        def handle_pip_compile_errors(error)
          if error.message.include?("Could not find a version")
            check_original_requirements_resolvable
            # If the original requirements are resolvable but we get an
            # incompatibility error after unlocking then it's likely to be
            # due to problems with pip-compile's cascading resolution
            return nil
          end

          if error.message.include?("UnsupportedConstraint")
            # If there's an unsupported constraint, check if it existed
            # previously (and raise if it did)
            check_original_requirements_resolvable
          end

          if (error.message.include?('Command "python setup.py egg_info') ||
              error.message.include?(
                "exit status 1: python setup.py egg_info"
              )) &&
             check_original_requirements_resolvable
            # The latest version of the dependency we're updating is borked
            # (because it has an unevaluatable setup.py). Skip the update.
            return
          end

          if error.message.include?("Could not find a version ") &&
             !error.message.match?(/#{Regexp.quote(dependency.name)}/i)
            # Sometimes pip-tools gets confused and can't work around
            # sub-dependency incompatibilities. Ignore those cases.
            return nil
          end

          if error.message.match?(GIT_DEPENDENCY_UNREACHABLE_REGEX)
            url = error.message.match(GIT_DEPENDENCY_UNREACHABLE_REGEX).
                  named_captures.fetch("url")
            raise GitDependenciesNotReachable, url
          end

          if error.message.match?(GIT_REFERENCE_NOT_FOUND_REGEX)
            name = error.message.match(GIT_REFERENCE_NOT_FOUND_REGEX).
                   named_captures.fetch("name")
            raise GitDependencyReferenceNotFound, name
          end

          raise
        end

        # rubocop:enable Metrics/AbcSize

        # Needed because pip-compile's resolver isn't perfect.
        # Note: We raise errors from this method, rather than returning a
        # boolean, so that all deps for this repo will raise identical
        # errors when failing to update
        def check_original_requirements_resolvable
          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              write_temporary_dependency_files(update_requirement: false)

              filenames_to_compile.each do |filename|
                run_pip_compile_command(
                  "pyenv exec pip-compile --allow-unsafe #{filename}"
                )
              end

              true
            rescue SharedHelpers::HelperSubprocessFailed => e
              unless e.message.include?("Could not find a version") ||
                     e.message.include?("UnsupportedConstraint")
                raise
              end

              msg = clean_error_message(e.message)
              raise if msg.empty?

              raise DependencyFileNotResolvable, msg
            end
          end
        end

        def run_command(command, env: python_env)
          start = Time.now
          command = SharedHelpers.escape_command(command)
          stdout, process = Open3.capture2e(env, command)
          time_taken = Time.now - start

          return stdout if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        def pip_compile_options(filename)
          options = ["--build-isolation"]
          options += pip_compile_index_options

          if (requirements_file = compiled_file_for_filename(filename))
            options << "--output-file=#{requirements_file.name}"
          end

          options.join(" ")
        end

        def pip_compile_index_options
          credentials.
            select { |cred| cred["type"] == "python_index" }.
            map do |cred|
              authed_url = AuthedUrlBuilder.authed_url(credential: cred)

              if cred["replaces-base"]
                "--index-url=#{authed_url}"
              else
                "--extra-index-url=#{authed_url}"
              end
            end
        end

        def run_pip_compile_command(command)
          run_command("pyenv local #{python_version}")
          run_command(command)
        rescue SharedHelpers::HelperSubprocessFailed => e
          original_err ||= e
          msg = e.message

          relevant_error = choose_relevant_error(original_err, e)
          raise relevant_error unless error_suggests_bad_python_version?(msg)
          raise relevant_error if user_specified_python_version
          raise relevant_error if python_version == "2.7.18"

          @python_version = "2.7.18"
          retry
        ensure
          @python_version = nil
          FileUtils.remove_entry(".python-version", true)
        end

        def choose_relevant_error(previous_error, new_error)
          return previous_error if previous_error == new_error

          # If the previous error was definitely due to using the wrong Python
          # version, return the new error (which can't be worse)
          if error_certainly_bad_python_version?(previous_error.message)
            return new_error
          end

          # Otherwise, if the new error may be due to using the wrong Python
          # version, return the old error (which can't be worse)
          if error_suggests_bad_python_version?(new_error.message)
            return previous_error
          end

          # Otherwise, default to the new error
          new_error
        end

        def python_env
          env = {}

          # Handle Apache Airflow 1.10.x installs
          if dependency_files.any? { |f| f.content.include?("apache-airflow") }
            if dependency_files.any? { |f| f.content.include?("unidecode") }
              env["AIRFLOW_GPL_UNIDECODE"] = "yes"
            else
              env["SLUGIFY_USES_TEXT_UNIDECODE"] = "yes"
            end
          end

          env
        end

        def error_certainly_bad_python_version?(message)
          return true if message.include?("UnsupportedPythonVersion")

          unless message.include?('"python setup.py egg_info" failed') ||
                 message.include?("exit status 1: python setup.py egg_info")
            return false
          end

          message.include?("SyntaxError")
        end

        def error_suggests_bad_python_version?(message)
          return true if error_certainly_bad_python_version?(message)
          return true if message.include?("not find a version that satisfies")
          return true if message.include?("No matching distribution found")

          message.include?('Command "python setup.py egg_info" failed') ||
            message.include?("exit status 1: python setup.py egg_info")
        end

        def write_temporary_dependency_files(updated_req: nil,
                                             update_requirement: true)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            updated_content =
              if update_requirement then update_req_file(file, updated_req)
              else file.content
              end
            File.write(path, updated_content)
          end

          # Overwrite the .python-version with updated content
          File.write(".python-version", python_version)

          setup_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, sanitized_setup_file_content(file))
          end

          setup_cfg_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, "[metadata]\nname = sanitized-package\n")
          end
        end

        def write_original_manifest_files
          pip_compile_files.each do |file|
            FileUtils.mkdir_p(Pathname.new(file.name).dirname)
            File.write(file.name, file.content)
          end
        end

        def install_required_python
          if run_command("pyenv versions").include?("#{python_version}\n")
            return
          end

          run_command("pyenv install -s #{python_version}")
          run_command("pyenv exec pip install -r"\
                      "#{NativeHelpers.python_requirements_path}")
        end

        def sanitized_setup_file_content(file)
          @sanitized_setup_file_content ||= {}
          if @sanitized_setup_file_content[file.name]
            return @sanitized_setup_file_content[file.name]
          end

          @sanitized_setup_file_content[file.name] =
            Python::FileUpdater::SetupFileSanitizer.
            new(setup_file: file, setup_cfg: setup_cfg(file)).
            sanitized_content
        end

        def setup_cfg(file)
          dependency_files.find do |f|
            f.name == file.name.sub(/\.py$/, ".cfg")
          end
        end

        def update_req_file(file, updated_req)
          return file.content unless file.name.end_with?(".in")

          req = dependency.requirements.find { |r| r[:file] == file.name }

          unless req&.fetch(:requirement)
            return file.content + "\n#{dependency.name} #{updated_req}"
          end

          Python::FileUpdater::RequirementReplacer.new(
            content: file.content,
            dependency_name: dependency.name,
            old_requirement: req[:requirement],
            new_requirement: updated_req
          ).updated_content
        end

        def normalise(name)
          NameNormaliser.normalise(name)
        end

        def clean_error_message(message)
          msg_lines = message.lines
          msg = msg_lines.
                take_while { |l| !l.start_with?("During handling of") }.
                drop_while { |l| l.start_with?("Traceback", "  ") }.
                join.strip

          # Redact any URLs, as they may include credentials
          msg.gsub(/http.*?(?=\s)/, "<redacted>")
        end

        def filenames_to_compile
          files_from_reqs =
            dependency.requirements.
            map { |r| r[:file] }.
            select { |fn| fn.end_with?(".in") }

          files_from_compiled_files =
            pip_compile_files.map(&:name).select do |fn|
              compiled_file = compiled_file_for_filename(fn)
              compiled_file_includes_dependency?(compiled_file)
            end

          filenames = [*files_from_reqs, *files_from_compiled_files].uniq

          order_filenames_for_compilation(filenames)
        end

        def compiled_file_for_filename(filename)
          compiled_file =
            compiled_files.
            find { |f| f.content.match?(output_file_regex(filename)) }

          compiled_file ||=
            compiled_files.
            find { |f| f.name == filename.gsub(/\.in$/, ".txt") }

          compiled_file
        end

        def output_file_regex(filename)
          "--output-file[=\s]+.*\s#{Regexp.escape(filename)}\s*$"
        end

        def compiled_file_includes_dependency?(compiled_file)
          return false unless compiled_file

          regex = RequirementParser::INSTALL_REQ_WITH_REQUIREMENT

          matches = []
          compiled_file.content.scan(regex) { matches << Regexp.last_match }
          matches.any? { |m| normalise(m[:name]) == dependency.name }
        end

        # If the files we need to update require one another then we need to
        # update them in the right order
        def order_filenames_for_compilation(filenames)
          ordered_filenames = []

          while (remaining_filenames = filenames - ordered_filenames).any?
            ordered_filenames +=
              remaining_filenames.
              select do |fn|
                unupdated_reqs = requirement_map[fn] - ordered_filenames
                (unupdated_reqs & filenames).empty?
              end
          end

          ordered_filenames
        end

        def requirement_map
          child_req_regex = Python::FileFetcher::CHILD_REQUIREMENT_REGEX
          @requirement_map ||=
            pip_compile_files.each_with_object({}) do |file, req_map|
              paths = file.content.scan(child_req_regex).flatten
              current_dir = File.dirname(file.name)

              req_map[file.name] =
                paths.map do |path|
                  path = File.join(current_dir, path) if current_dir != "."
                  path = Pathname.new(path).cleanpath.to_path
                  path = path.gsub(/\.txt$/, ".in")
                  next if path == file.name

                  path
                end.uniq.compact
            end
        end

        def parse_updated_files
          updated_files =
            dependency_files.map do |file|
              next file if file.name == ".python-version"

              updated_file = file.dup
              updated_file.content = File.read(file.name)
              updated_file
            end

          Python::FileParser.new(
            dependency_files: updated_files,
            source: nil,
            credentials: credentials
          ).parse.find { |d| d.name == dependency.name }&.version
        end

        def python_version
          @python_version ||=
            user_specified_python_version ||
            python_version_matching_imputed_requirements ||
            PythonVersions::PRE_INSTALLED_PYTHON_VERSIONS.first
        end

        def user_specified_python_version
          unless python_requirement_parser.user_specified_requirements.any?
            return
          end

          user_specified_requirements =
            python_requirement_parser.user_specified_requirements.
            map { |r| Python::Requirement.requirements_array(r) }
          python_version_matching(user_specified_requirements)
        end

        def python_version_matching_imputed_requirements
          compiled_file_python_requirement_markers =
            python_requirement_parser.imputed_requirements.map do |r|
              Dependabot::Python::Requirement.new(r)
            end
          python_version_matching(compiled_file_python_requirement_markers)
        end

        def python_version_matching(requirements)
          PythonVersions::SUPPORTED_VERSIONS_TO_ITERATE.find do |version_string|
            version = Python::Version.new(version_string)
            requirements.all? do |req|
              next req.any? { |r| r.satisfied_by?(version) } if req.is_a?(Array)

              req.satisfied_by?(version)
            end
          end
        end

        def python_requirement_parser
          @python_requirement_parser ||=
            FileParser::PythonRequirementParser.new(
              dependency_files: dependency_files
            )
        end

        def pre_installed_python?(version)
          PythonVersions::PRE_INSTALLED_PYTHON_VERSIONS.include?(version)
        end

        def setup_files
          dependency_files.select { |f| f.name.end_with?("setup.py") }
        end

        def pip_compile_files
          dependency_files.select { |f| f.name.end_with?(".in") }
        end

        def compiled_files
          dependency_files.select { |f| f.name.end_with?(".txt") }
        end

        def setup_cfg_files
          dependency_files.select { |f| f.name.end_with?("setup.cfg") }
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
