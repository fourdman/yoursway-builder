

# def post_multipart(host, selector, fields, files):
#     content_type, body = encode_multipart_formdata(fields, files)
#     h = httplib.HTTPConnection(host)
#     headers = {
#         'User-Agent': 'INSERT USERAGENTNAME',
#         'Content-Type': content_type
#         }
#     h.request('POST', selector, body, headers)
#     res = h.getresponse()
#     return res.status, res.reason, res.read()


require 'net/http'
require 'uri'
require 'optparse'

BUILDER_ROOT = File.expand_path(File.dirname(__FILE__))
Dir.chdir BUILDER_ROOT
$:.unshift BUILDER_ROOT

def is_windows?
  RUBY_PLATFORM =~ /(mswin|cygwin|mingw)(32|64)/
end

class Reloader
  
  def initialize
    @prev_length = $:.length
    @recorded_modules = []
  end
  
  def record! file_spec
    expanded_path = File.expand_path(file_spec)
    if expanded_path[0..BUILDER_ROOT.length-1] == BUILDER_ROOT && File.exists?(expanded_path)
      @recorded_modules << [expanded_path, File.mtime(expanded_path)]
    end
  end
  
  def record_all_required!
    file_specs = $"[@prev_length..-1]
    file_specs.each do |file_spec|
      record! file_spec
    end
  end
  
  def find_module_to_reload
    @recorded_modules.find { |file, mtime| File.mtime(file) != mtime }
  end
  
  def reload_needed?
    !!find_module_to_reload
  end
  
  def check_and_maybe_quit!
    if changes = find_module_to_reload
      file, mtime = changes
      puts "Restarting this builder because '#{file[BUILDER_ROOT.length+1..-1]}' has been changed on disk."
      puts
      exit! 22
    end
  end
  
end

$reloader = Reloader.new
require 'executor'
$reloader.record_all_required!
$reloader.record! __FILE__

class Config
  attr_accessor :server_host, :builder_name
  attr_accessor :poll_interval, :poll_interval_overriden
end
config = Config.new
config.server_host = "localhost:8080"
config.builder_name = `hostname`.strip.gsub(/\..*$/, '')
config.poll_interval = 59 # a default, will be overridden from the server
config.poll_interval_overriden = false

OptionParser.new do |opts|
  opts.banner = "Usage: ruby worker.rb [options]"
  
  opts.on( "-s", "--server SERVER", String, "the address of the YourSway Builder server to connect to (host or host:port)" ) do |opt|
    config.server_host = opt
  end
  
  opts.on("-n", "--name NAME", String, "builder name (e.g. andreyvitmb)" ) do |opt|
    config.builder_name = opt
  end

  opts.on_tail("--default-poll SECONDS", Integer, "default poll interval (used only if the server is not reachable)") do |val|
    config.poll_interval = val
  end

  opts.on_tail("--poll SECONDS", Integer, "override poll interval (ignore the interval set by the server)") do |val|
    config.poll_interval = val
    config.poll_interval_overriden = true
  end

  opts.on_tail("-U", "Allow self-updating (git fetch, git reset --hard)") do
    # processed by the launcher script, has no effect here
  end

  opts.on_tail("-H", "--help", "Show this message") do
    puts opts
    exit
  end

  opts.on_tail("--version", "Show version") do
    puts "unknown version"
    exit
  end
end.parse!

puts
puts "=============================================================================="
puts "YourSway Builder build host"
puts
puts "Please verify that the following is correct. Push Ctrl-C to stop this builder."
puts
puts "Server:              #{config.server_host}"
puts "Builder name:        #{config.builder_name}"
if config.poll_interval_overriden
puts "Fixed poll interval: #{config.poll_interval} seconds"
end
puts "=============================================================================="
puts

interrupted = false
# trap("INT") { interrupted = true }

class NetworkError < StandardError
end

class ServerCommunication
  
  attr_writer :retry_interval
  
  def initialize feedback, server_host, builder_name, retry_interval
    @builder_name = builder_name
    @server_host = server_host
    @obtain_work_uri = URI.parse("http://#{@server_host}/builders/#{@builder_name}/obtain-work")
    @retry_interval = retry_interval
  end
  
  def obtain_work
    post "Asking #{@server_host} to provide new jobs...",
      @obtain_work_uri, 'token' => 42
  end
  
  def job_done message_id, data
    post "Reporting job results to #{@server_host}...",
      message_done_uri(message_id), data.merge('token' => 42)
  end
  
private

  def message_done_uri(message_id)
    URI.parse("http://#{@server_host}/builders/#{@builder_name}/messages/%s/done" % message_id)
  end

  def post(message, uri, vars = {})
    network_operation(message) do
      Net::HTTP.post_form(uri, vars)
    end
  end

  def network_operation message, &block
    begin
      puts message
      return try_network_operation(&block)
    rescue NetworkError => e
      puts e.message
      puts "Will retry in #{@retry_interval} seconds."
      sleep @retry_interval
      retry
    end
  end

  def try_network_operation
    begin
      response = yield
      return response.body if (200...300) === response.code.to_i
      raise NetworkError, "Server returned error response #{response.code}"
    rescue Errno::ECONNREFUSED => e
      raise NetworkError, "Connection refused: #{e}" 
    rescue Errno::EPIPE => e
      raise NetworkError, "Broken pipe: #{e}" 
    rescue Errno::ECONNRESET => e
      raise NetworkError, "Connection reset: #{e}" 
    rescue Errno::ECONNABORTED => e
      raise NetworkError, "Connection aborted: #{e}" 
    rescue Errno::ETIMEDOUT => e
      raise NetworkError, "Connection timed out: #{e}"
    rescue Timeout::Error => e
      raise NetworkError, "Connection timed out: #{e}" 
    rescue SocketError => e
      raise NetworkError, "Socket error: #{e}" 
    rescue EOFError => e
      raise NetworkError, "EOF error: #{e}"
    end
  end
  
end

class ConsoleFeedback
  
  def start_job id
    puts "Starting job #{id}"
  end
  
  def start_command command, complexity
    raise "Invalid complexity #{complexity}" unless [:short, :long].include?(complexity)
    puts "Starting command #{command}"
  end
  
  def finished_command
    puts "Finished command."
  end
  
  def job_done id, options
    outcome = options[:outcome]
    if outcome == 'SUCCESS'
      puts "Successfully finished job #{id}"
    else
      puts "FAILURE REASON (message id #{message_id})\n"
      puts "#{failure_reason}"
      puts "END FAILURE REASON (message id #{message_id})"
    end
  end
  
  def command_output output
    puts output
  end
  
  def error message
    puts message
  end
  
  def info message
    puts message
  end
  
end

class NetworkFeedback
  
  def initialize communicator
    @communicator = communicator
  end
  
  def start_job id
    @job_id = id
  end
  
  def start_command command, complexity
  end
  
  def finished_command
  end
  
  def job_done id, options
    @comm.job_done id, options
  end
  
  def command_output output
  end
  
  def error message
  end
  
  def info message
  end
  
end

class Multicast
  
  def initialize *targets
    @targets = targets
  end
  
  def method_missing id, *args
    @targets.each { |t| t.send(id, *args) }
  end
  
end

feedback = ConsoleFeedback.new
comm = ServerCommunication.new(feedback, config.server_host, config.builder_name, config.poll_interval)

class ExecutionError < Exception
end

def process_job feedback, builder_name, message_id
  feedback.start_job message_id
  report = nil
  outcome = "SUCCESS"
  begin
    executor = Executor.new(builder_name, feedback)

    until other_lines.empty?
      line = other_lines.shift.chomp
      next if line.strip.empty?
      next if line =~ /^\s*#/
  
      command, *args = line.split("\t")
      data = []
      until other_lines.empty?
        line = other_lines.shift.chomp
        next if line.strip.empty?
        next if line =~ /^\s*#/
        if line[0..0] == "\t"
          data << line[1..-1].split("\t")
        else
          other_lines.unshift line
          break
        end
      end
  
      executor.execute command, args, data
    end
  
    report = executor.create_report.collect { |row| row.join("\t") }.join("\n")
  rescue Exception
    outcome = "ERR"
    failure_reason = "#{$!.class.name}: #{$!.message}\n#{($!.backtrace || []).join("\n")}"
  end
  feedback.job_done message_id, :report => report, :outcome => outcome, :failure_reason => failure_reason
end

while not interrupted
  $reloader.check_and_maybe_quit!
  
  response_body = comm.obtain_work
  unless response_body.nil?
    first_line, *other_lines = response_body.split("\n")

    result = []
    message_id = nil
    
    command, *args = first_line.chomp.split("\t")
    command.upcase!
    unless ['IDLE', 'ENVELOPE', 'SELFUPDATE'].include?(command)
      feedback.error "Unknown command received (#{command}), initiating self-update in #{config.poll_interval} seconds."
      sleep config.poll_interval
      exit! 55
    end
      
    proto_ver = args[0]
    unless proto_ver == 'v1'
      feedback.error "Unsupported protocol version detected (#{proto_ver}), initiating self-update in #{config.poll_interval} seconds."
      sleep config.poll_interval
      exit! 55
    end
    
    case command
    when 'IDLE'
      new_interval = [60*20, args[1].to_i].min
      if !config.poll_interval_overriden && new_interval >= 10 && config.poll_interval != new_interval
        config.poll_interval = new_interval
        comm.retry_interval  = new_interval
        feedback.info "Poll interval set to #{config.poll_interval}"
      end
      
      feedback.info "No outstanding jobs, gonna be lazing for #{config.poll_interval} seconds."
      sleep config.poll_interval
    when 'SELFUPDATE'
      exit!(55)
    else
      message_id = args[1]
      process_job Multicast.new(feedback, NetworkFeedback.new(comm)), config.builder_name, message_id
    end
  end
end
