# typed: true
# frozen_string_literal: true

module Dependabot
  module NpmAndYarn
    module Helpers
      def self.npm_version(lockfile_content)
        "npm#{npm_version_numeric(lockfile_content)}"
      end

      def self.npm_version_numeric(lockfile_content)
        return 8 unless lockfile_content
        return 8 if JSON.parse(lockfile_content)["lockfileVersion"] >= 2

        6
      rescue JSON::ParserError
        6
      end

      def self.yarn_version_numeric(yarn_lock)
        if yarn_berry?(yarn_lock)
          3
        else
          1
        end
      end

      # Mapping from lockfile versions to PNPM versions is at
      # https://github.com/pnpm/spec/tree/274ff02de23376ad59773a9f25ecfedd03a41f64/lockfile, but simplify it for now.
      def self.pnpm_version_numeric(pnpm_lock)
        if pnpm_lockfile_version(pnpm_lock).to_f >= 5.4
          8
        else
          6
        end
      end

      def self.fetch_yarnrc_yml_value(key, default_value)
        if File.exist?(".yarnrc.yml") && (yarnrc = YAML.load_file(".yarnrc.yml"))
          yarnrc.fetch(key, default_value)
        else
          default_value
        end
      end

      def self.yarn_berry?(yarn_lock)
        yaml = YAML.safe_load(yarn_lock.content)
        yaml.key?("__metadata")
      rescue StandardError
        false
      end

      def self.yarn_major_version
        retries = 0
        output = SharedHelpers.run_shell_command("yarn --version")
        Version.new(output).major
      rescue Dependabot::SharedHelpers::HelperSubprocessFailed => e
        # Should never happen, can probably be removed once this settles
        raise "Failed to replace ENV, not sure why" if T.must(retries).positive?

        message = e.message

        missing_env_var_regex = %r{Environment variable not found \((?:[^)]+)\) in #{Dir.pwd}/(?<path>\S+)}

        if message.match?(missing_env_var_regex)
          match = T.must(message.match(missing_env_var_regex))
          path = T.must(match.named_captures["path"])

          File.write(path, File.read(path).gsub(/\$\{[^}-]+\}/, ""))
          retries = T.must(retries) + 1

          retry
        end

        raise
      end

      def self.yarn_zero_install?
        File.exist?(".pnp.cjs")
      end

      def self.yarn_offline_cache?
        yarn_cache_dir = fetch_yarnrc_yml_value("cacheFolder", ".yarn/cache")
        File.exist?(yarn_cache_dir) && (fetch_yarnrc_yml_value("nodeLinker", "") == "node-modules")
      end

      def self.yarn_berry_args
        if yarn_major_version == 2
          ""
        elsif yarn_berry_skip_build?
          "--mode=skip-build"
        else
          # We only want this mode if the cache is not being updated/managed
          # as this improperly leaves old versions in the cache
          "--mode=update-lockfile"
        end
      end

      def self.yarn_berry_skip_build?
        yarn_major_version >= 3 && (yarn_zero_install? || yarn_offline_cache?)
      end

      def self.yarn_berry_disable_scripts?
        yarn_major_version == 2 || !yarn_zero_install?
      end

      def self.yarn_4_or_higher?
        yarn_major_version >= 4
      end

      def self.setup_yarn_berry
        # Always disable immutable installs so yarn's CI detection doesn't prevent updates.
        SharedHelpers.run_shell_command("yarn config set enableImmutableInstalls false")
        # Do not generate a cache if offline cache disabled. Otherwise side effects may confuse further checks
        SharedHelpers.run_shell_command("yarn config set enableGlobalCache true") unless yarn_berry_skip_build?
        # We never want to execute postinstall scripts, either set this config or mode=skip-build must be set
        SharedHelpers.run_shell_command("yarn config set enableScripts false") if yarn_berry_disable_scripts?
        if (http_proxy = ENV.fetch("HTTP_PROXY", false))
          SharedHelpers.run_shell_command("yarn config set httpProxy #{http_proxy}")
        end
        if (https_proxy = ENV.fetch("HTTPS_PROXY", false))
          SharedHelpers.run_shell_command("yarn config set httpsProxy #{https_proxy}")
        end
        return unless (ca_file_path = ENV.fetch("NODE_EXTRA_CA_CERTS", false))

        if yarn_4_or_higher?
          SharedHelpers.run_shell_command("yarn config set httpsCaFilePath #{ca_file_path}")
        else
          SharedHelpers.run_shell_command("yarn config set caFilePath #{ca_file_path}")
        end
      end

      # Run any number of yarn commands while ensuring that `enableScripts` is
      # set to false. Yarn commands should _not_ be ran outside of this helper
      # to ensure that postinstall scripts are never executed, as they could
      # contain malicious code.
      def self.run_yarn_commands(*commands)
        setup_yarn_berry
        commands.each { |cmd, fingerprint| SharedHelpers.run_shell_command(cmd, fingerprint: fingerprint) }
      end

      # Run a single yarn command returning stdout/stderr
      def self.run_yarn_command(command, fingerprint: nil)
        setup_yarn_berry
        SharedHelpers.run_shell_command(command, fingerprint: fingerprint)
      end

      def self.pnpm_lockfile_version(pnpm_lock)
        pnpm_lock.content.match(/^lockfileVersion: ['"]?(?<version>[\d.]+)/)[:version]
      end

      def self.dependencies_with_all_versions_metadata(dependency_set)
        dependency_set.dependencies.map do |dependency|
          dependency.metadata[:all_versions] = dependency_set.all_versions_for_name(dependency.name)
          dependency
        end
      end
    end
  end
end
