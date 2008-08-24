

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

class Config
  attr_accessor :server_host, :builder_name
  attr_accessor :poll_interval
end
config = Config.new
config.server_host = "localhost:8080"
config.builder_name = "bar"

# a default, will be overridden from the server
config.poll_interval = 59

interrupted = false
trap("INT") { interrupted = true }

uri = URI.parse("http://#{config.server_host}/builders/obtain-work")

def log message
  puts message
end

while not interrupted
  res = Net::HTTP.post_form(uri, {
      'name' => config.builder_name,
    })
  if res.code.to_i != 200
    log "Error response: code #{res.code}"
  else
    res.body.split("\n").each do |line|
      next if (line = line.strip).empty?
      command, *args = line.split("\t")
      case command
      when 'SETPOLL'
        new_interval = [60*20, args[0].to_i].min
        if new_interval >= 30 && config.poll_interval != new_interval
          config.poll_interval = new_interval
          log "Poll interval set to #{config.poll_interval}"
        end
      end
    end
  end
  
  log "Sleeping for #{config.poll_interval} seconds"
  sleep config.poll_interval
end
