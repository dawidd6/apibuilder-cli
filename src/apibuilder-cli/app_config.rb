# Reads the apibuilder application configuration file (.apibuilder/config filename by convention)
module ApibuilderCli

  class AppConfig

    DEFAULT_FILENAMES = ["#{ApibuilderCli::Config::APIBUILDER_LOCAL_DIR}/config", ".apibuilder", ".apidoc"] unless defined?(DEFAULT_FILENAMES)

    attr_reader :settings, :code, :project_dir, :attributes

    def AppConfig.default_path
      path = find_config_file
      path_root = Dir.pwd
      if path.nil?
        git_root = `git rev-parse --show-toplevel 2> /dev/null`.strip
        if git_root != ""
          path = find_config_file(git_root)
          path_root = git_root unless path.nil?
        end
      end
      if path.nil?
        puts "**ERROR** Could not find apibuilder configuration file. Expected file to be located in current directory or the project root directory and named: %s" % DEFAULT_FILENAMES.first
        exit(1)
      end
      if path != DEFAULT_FILENAMES.first
        puts "******************** WARNING ********************"
        puts "** File %s is now deprecated and should be named %s. Moving it..." % [path, DEFAULT_FILENAMES.first]
        ["git mv #{path} .apibuilder.tmp", "mkdir #{ApibuilderCli::Config::APIBUILDER_LOCAL_DIR}", "git mv .apibuilder.tmp #{DEFAULT_FILENAMES.first}"].each do |cmd|
          puts "** #{cmd}"
          `#{cmd}`
        end
        puts "*************************************************"
        path = DEFAULT_FILENAMES.first
      end
      full_path = Util.file_join(path_root, path)
      # ~/.apibuilder/config is the global conf file, which should not be handled as an app config
      if full_path == Config.default_path
        puts "**ERROR** Could not find apibuilder configuration file. Please run apibuilder from a repository."
        exit(1)
      end
      full_path
    end

    def AppConfig.find_config_file(root_dir = nil)
      DEFAULT_FILENAMES.find { |p| File.exists?(Util.file_join(root_dir, p)) }
    end
      
    def AppConfig.parse_project_dir(path)
      project_dir = File.dirname(path)
      # If the config file is buried in a directory starting with '.', bubble up to the
      # directory that contains that '.' directory.
      nested_dirs = project_dir
                      .split("/")
                      .reverse
                      .drop_while{ |dir| !dir.start_with?(".") }
      nested_dirs = nested_dirs.drop(1) if nested_dirs.length > 0 && nested_dirs[0].start_with?(".")
      project_dir = nested_dirs.reverse.join("/") if nested_dirs.length > 0
      project_dir
    end

    def initialize(opts={})
      @path = Preconditions.assert_class(opts.delete(:path) || AppConfig.default_path, String)
      Preconditions.check_state(File.exists?(@path), "Apibuilder application config file[#{@path}] not found")

      contents = IO.read(@path)
      @yaml = begin
               YAML.load(contents)
             rescue Psych::SyntaxError => e
               puts "ERROR parsing YAML file at #{@path}:\n  #{e}"
               exit(1)
             end

      @settings = Settings.new((@yaml['settings'] || {}).clone) # NB: clone is not deep, so this will not work if settings become nested
      @attributes = Attributes.new((@yaml['attributes'] || {}))
      def get_generator_attributes_by_name(name, override_attributes)
        # @param name generator name
        # @param pattern e.g. "play_client" or "play*"
        def matches(name, pattern)
          if pattern == "*"
            true
          elsif pattern.end_with?("*")
            name.start_with?(pattern[0, pattern.length - 1])
          else
            name == pattern
          end
        end

        all = @attributes.generators.select { |ga| matches(name, ga.generator_name) }
        all.inject(override_attributes) {|fin, ga| fin.merge(ga.attributes) }
      end

      code_projects = (@yaml["code"] || {}).map do |org_key, project_map|
        project_map.map do |project_name, data|
          attributes = data['attributes'] || {}
          version = data['version'].to_s.strip
          if version == ""
            raise "File[#{@path}] Missing version for org[#{org_key}] project[#{project_name}]"
          end
          if data['generators'].is_a?(Hash)
            generators = data['generators'].map do |name, data|
              Generator.new(name, data, get_generator_attributes_by_name(name, {}))
            end
          elsif data['generators'].is_a?(Array)
            generators = data['generators'].map do |generator|
              name = generator['generator']
              Generator.new(name, generator, get_generator_attributes_by_name(name, generator['attributes'] || {}))
            end
          else
            raise "File[#{@path}] Missing generators for org[#{org_key}] project[#{project_name}]"
          end
          project = Project.new(org_key, project_name, version, generators)
        end
      end.flatten

      @code = Code.new(code_projects)

      @project_dir = AppConfig.parse_project_dir(@path)
    end

    def save!
      IO.write(@path, @yaml.to_yaml)
    end

    def set_version(org_key, project_name, version)
      if version.empty?
        raise "Version missing"
      elsif @yaml["code"].nil? || @yaml["code"][org_key].nil? || @yaml["code"][org_key][project_name].nil?
        raise "File[#{@path}] Missing config for org[#{org_key}] project[#{project_name}]"
      else
        @yaml["code"][org_key][project_name]['version'] = version
      end
    end

    class Code

      attr_reader :projects

      def initialize(projects)
        @projects = Preconditions.assert_class(projects, Array)
        Preconditions.assert_class_or_nil(projects.first, Project)
      end

    end

    class Attributes

      attr_reader :generators

      def initialize(data)
        @generators = (data['generators'] || []).map { |name, attributes| GeneratorAttribute.new(name, attributes) }
      end

    end

    class GeneratorAttribute

      attr_reader :generator_name, :attributes

      def initialize(generator_name, attributes)
        @generator_name = generator_name
        @attributes = attributes
      end
    end

    class Settings

      attr_reader :code_create_directories, :code_cleanup_generated_files

      def initialize(data)
        @code_create_directories = data.has_key?("code.create.directories") ? data.delete("code.create.directories") : false
        @code_cleanup_generated_files = data.has_key?("code.cleanup.generated.files") ? data.delete("code.cleanup.generated.files") : false
        Preconditions.check_state(data.empty?, "Invalid settings: #{data.keys.sort}")
      end

    end
    
    class Project

      attr_reader :org, :name, :version, :generators

      def initialize(org, name, version, generators)
        @org = Preconditions.assert_class(org, String)
        @name = Preconditions.assert_class(name, String)
        @version = Preconditions.assert_class(version, String)
        @generators = Preconditions.assert_class(generators, Array)
        Preconditions.check_state(!generators.empty?, "Must have at least one generator")
        Preconditions.assert_class(generators.first, Generator)
      end

    end

    class Generator

      attr_reader :name, :targets, :files, :attributes

      # @param target The name of a file path or a
      # directory. Preferred usage is a directory, but paths are
      # supported based on the initial version of the configuration
      # files.
      def initialize(name, data, attributes)
        @name = Preconditions.assert_class(name, String)
        @attributes = attributes || {}
        if data.is_a?(Array)
          Preconditions.assert_class(data.first, String)
          @targets = data
          @files = nil
        elsif data.is_a?(String)
          Preconditions.assert_class(data, String)
          @targets = [data]
          @files = nil
        elsif data['files'].nil?
          Preconditions.assert_class(data['target'], String)
          @targets = [data['target']]
          @files = nil
        elsif data['files'].is_a?(Array)
          Preconditions.assert_class(data['target'], String)
          Preconditions.assert_class(data['files'].first, String)
          @targets = [data['target']]
          @files = data['files']
        else
          Preconditions.assert_class(data['target'], String)
          Preconditions.assert_class(data['files'], String)
          @targets = [data['target']]
          @files = [data['files']]
        end
      end
    end

  end

end
