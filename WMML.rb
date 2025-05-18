require 'json'
require 'open3'
require 'fileutils'

# Launches Minecraft with the specified parameters
# @param [String] mc_path Path to .minecraft directory
# @param [String] version_name Minecraft version name
# @param [String] player_name Player username
# @param [Hash] options Launch options
# @option options [String] :java_path Path to Java executable
# @option options [Integer] :memory Memory allocation in MB
# @option options [Boolean] :use_system_memory Whether to use system memory detection
def launch_minecraft(mc_path, version_name, player_name, options = {})
  begin
    # Normalize path
    mc_path += '/' unless mc_path.end_with?('/')

    # Read version JSON file
    version_json_path = File.join(mc_path, 'versions', version_name, "#{version_name}.json")
    version_json = read_json_file(version_json_path)

    # Get main class
    main_class = version_json['mainClass']

    # Build libraries path
    libraries = build_libraries_path(mc_path, version_json)

    # Build game arguments
    game_args = build_game_arguments(mc_path, version_name, player_name, version_json)

    # Build Java command
    java_command = build_java_command(mc_path, version_name, main_class, libraries, game_args, options)

    # Execute command
    puts "Launching Minecraft with command: #{java_command}"
    pid = spawn(java_command)
    Process.detach(pid)

    puts "Minecraft launched with PID: #{pid}"
    pid

  rescue => error
    puts "Error launching Minecraft: #{error}"
    raise error
  end
end

# Builds the libraries classpath
# @param [String] mc_path Path to .minecraft directory
# @param [Hash] version_json Version JSON object
def build_libraries_path(mc_path, version_json)
  # Start with the version jar
  result = [File.join(mc_path, 'versions', version_json['id'], "#{version_json['id']}.jar")]

  # Add all libraries
  if version_json['libraries'] && version_json['libraries'].is_a?(Array)
    version_json['libraries'].each do |lib|
      # Check library rules
      next unless check_library_rules(lib)

      # Get library path
      lib_path = get_library_path(mc_path, lib)
      result << lib_path if lib_path && !lib_path.empty?
    end
  end

  result.join(File::PATH_SEPARATOR)
end

# Checks if a library should be included based on rules
# @param [Hash] lib Library object
def check_library_rules(lib)
  # If no rules, always include
  return true unless lib['rules'] && !lib['rules'].empty?

  os_name = 'windows'
  os_arch = RbConfig::CONFIG['host_cpu'] == 'x64' ? 'x86_64' : 'x86'

  should_include = true

  lib['rules'].each do |rule|
    if rule['action'] == 'allow'
      # If no OS specified, allow
      unless rule['os']
        should_include = true
        next
      end

      # Check OS condition
      if rule['os']['name'] == os_name
        # Check arch if specified
        if rule['os']['arch']
          should_include = (rule['os']['arch'] == os_arch)
        else
          should_include = true
        end
      else
        should_include = false
      end
    elsif rule['action'] == 'disallow'
      # If no OS specified, disallow
      unless rule['os']
        should_include = false
        next
      end

      # Check OS condition
      if rule['os']['name'] == os_name
        should_include = false
      end
    end
  end

  should_include
end

# Gets the path to a library file
# @param [String] mc_path Path to .minecraft directory
# @param [Hash] lib Library object
def get_library_path(mc_path, lib)
  begin
    parts = lib['name'].split(':')
    group_path = parts[0].gsub('.', '/')
    artifact_id = parts[1]
    version = parts[2]

    # Base path
    base_path = File.join(mc_path, 'libraries', group_path, artifact_id, version)
    base_file = "#{artifact_id}-#{version}"

    # Check for natives
    if lib['natives'] && lib['natives']['windows']
      classifier = lib['natives']['windows'].gsub('${arch}', RbConfig::CONFIG['host_cpu'] == 'x64' ? '64' : '32')
      native_path = File.join(base_path, "#{base_file}-#{classifier}.jar")

      if File.exist?(native_path)
        return native_path
      end
    end

    # Default to regular jar
    jar_path = File.join(base_path, "#{base_file}.jar")
    return jar_path if File.exist?(jar_path)

    ''
  rescue => error
    puts "Error getting library path: #{error}"
    ''
  end
end

# Builds the game arguments string
# @param [String] mc_path Path to .minecraft directory
# @param [String] version_name Minecraft version name
# @param [String] player_name Player username
# @param [Hash] version_json Version JSON object
def build_game_arguments(mc_path, version_name, player_name, version_json)
  assets_path = File.join(mc_path, 'assets')
  assets_index = version_json['assets'] || ''

  args = ''

  # Handle older versions with minecraftArguments
  if version_json['minecraftArguments']
    args = version_json['minecraftArguments']
  end

  # Handle newer versions with arguments.game
  if version_json['arguments'] && version_json['arguments']['game']
    version_json['arguments']['game'].each do |arg|
      if arg.is_a?(String)
        args += ' ' + arg
      end
    end
  end

  # Replace placeholders
  args = args.gsub(/\$\{auth_player_name\}/, player_name)
  args = args.gsub(/\$\{version_name\}/, version_name)
  args = args.gsub(/\$\{game_directory\}/, mc_path)
  args = args.gsub(/\$\{assets_root\}/, assets_path)
  args = args.gsub(/\$\{assets_index_name\}/, assets_index)
  args = args.gsub(/\$\{auth_uuid\}/, '00000000-0000-0000-0000-000000000000')
  args = args.gsub(/\$\{auth_access_token\}/, '00000000000000000000000000000000')
  args = args.gsub(/\$\{user_type\}/, 'legacy')
  args = args.gsub(/\$\{version_type\}/, '"WMML 0.1.26"')

  args.strip
end

# Builds the complete Java command
# @param [String] mc_path Path to .minecraft directory
# @param [String] version_name Minecraft version name
# @param [String] main_class Main class to launch
# @param [String] libraries Classpath string
# @param [String] game_args Game arguments string
# @param [Hash] options Launch options
def build_java_command(mc_path, version_name, main_class, libraries, game_args, options)
  java_path = options[:java_path] || 'java'
  memory = options[:memory]
  use_system_memory = options[:use_system_memory] || false

  # Memory settings
  memory_settings = ''
  unless use_system_memory || memory.nil?
    memory_settings = "-Xmx#{memory}M -Xms#{memory}M "
  end

  # Common JVM arguments
  common_args = [
    '-Dfile.encoding=GB18030',
    '-Dsun.stdout.encoding=GB18030',
    '-Dsun.stderr.encoding=GB18030',
    '-Djava.rmi.server.useCodebaseOnly=true',
    '-Dcom.sun.jndi.rmi.object.trustURLCodebase=false',
    '-Dcom.sun.jndi.cosnaming.object.trustURLCodebase=false',
    '-Dlog4j2.formatMsgNoLookups=true',
    "-Dlog4j.configurationFile=#{File.join(mc_path, 'versions', version_name, 'log4j2.xml')}",
    "-Dminecraft.client.jar=#{File.join(mc_path, 'versions', version_name, "#{version_name}.jar")}",
    '-XX:+UnlockExperimentalVMOptions',
    '-XX:+UseG1GC',
    '-XX:G1NewSizePercent=20',
    '-XX:G1ReservePercent=20',
    '-XX:MaxGCPauseMillis=50',
    '-XX:G1HeapRegionSize=32m',
    '-XX:-UseAdaptiveSizePolicy',
    '-XX:-OmitStackTraceInFastThrow',
    '-XX:-DontCompileHugeMethods',
    '-Dfml.ignoreInvalidMinecraftCertificates=true',
    '-Dfml.ignorePatchDiscrepancies=true',
    '-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump',
    "-Djava.library.path=#{File.join(mc_path, 'versions', version_name, 'natives-windows-x86_64')}",
    "-Djna.tmpdir=#{File.join(mc_path, 'versions', version_name, 'natives-windows-x86_64')}",
    "-Dorg.lwjgl.system.SharedLibraryExtractPath=#{File.join(mc_path, 'versions', version_name, 'natives-windows-x86_64')}",
    "-Dio.netty.native.workdir=#{File.join(mc_path, 'versions', version_name, 'natives-windows-x86_64')}",
    '-Dminecraft.launcher.brand=WMML',
    '-Dminecraft.launcher.version=0.1.26'
  ].join(' ')

  # Construct full command
  "#{java_path} #{memory_settings}#{common_args} -cp \"#{libraries}\" #{main_class} #{game_args}"
end

# Reads a JSON file and parses it
# @param [String] file_path Path to JSON file
def read_json_file(file_path)
  begin
    content = File.read(file_path)
    JSON.parse(content)
  rescue => error
    puts "Error reading JSON file #{file_path}: #{error}"
    raise error
  end
end

# Example usage
mc_path = '.minecraft'
version_name = '1.20.1'
player_name = 'Player123'

options = {
  java_path: 'java',
  memory: 4096,
  use_system_memory: false
}

begin
  pid = launch_minecraft(mc_path, version_name, player_name, options)
  puts "Minecraft launched with PID: #{pid}"
rescue => e
  puts "Failed to launch Minecraft: #{e}"
end