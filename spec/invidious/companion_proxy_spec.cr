# Run independently: crystal spec spec/invidious/companion_proxy_spec.cr -Drunning_by_self
# The application globals below must not collide with the main spec helper.
{% skip_file unless flag?(:running_by_self) %}

require "http/client"
require "http/server"
require "http_proxy"
require "db"
require "pg"
require "spectator"
require "../../src/invidious/helpers/crystal_class_overrides"
require "../../src/invidious/yt_backend/socks_proxy"

class Config
  record CompanionConfig, private_url : URI
end

class CompanionProxySpecConfig
  property invidious_companion = [] of Config::CompanionConfig
  getter http_proxy : Nil = nil
  getter force_resolve = Socket::Family::INET
  getter cookies = [] of HTTP::Cookie
  getter pool_size = 1
end

class CompanionProxySpecLogger
  getter messages = [] of String

  def error(message : String)
    @messages << message
  end
end

CONFIG = CompanionProxySpecConfig.new
LOGGER = CompanionProxySpecLogger.new

require "../../src/invidious/yt_backend/connection_pool"

COMPANION_POOL = CompanionConnectionPool.new(capacity: 1)

require "../../src/invidious/routes/companion"

class CompanionProxySpecServer
  @@instances = [] of CompanionProxySpecServer
  getter requests = [] of String
  getter bodies = [] of String
  getter url : URI

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @url = URI.parse("http://127.0.0.1:#{@server.local_address.port}")
    @clients = [] of TCPSocket
    @@instances << self
    spawn do
      while socket = @server.accept?
        socket.read_timeout = 2.seconds
        @clients << socket
        spawn handle(socket)
      end
    end
  end

  def self.close_all
    @@instances.each(&.close)
    @@instances.clear
  end

  def close
    @server.close
    @clients.each(&.close)
  end

  private def handle(socket)
    while request = HTTP::Request.from_io(socket)
      break unless request.is_a?(HTTP::Request)
      @requests << request.path
      @bodies << (request.body.try(&.gets_to_end) || "")
      case request.path
      when "/slow"
        sleep 150.milliseconds
        reply(socket, "video/mp4", "previous-video")
      when "/partial"
        socket << "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 131072\r\n\r\n"
        socket.write(Bytes.new(65536, 0x42_u8))
        socket.flush
        sleep 150.milliseconds
        break
      else
        reply(socket, "application/dash+xml", "<MPD/>")
      end
    end
  rescue IO::Error
    # Timeout/cancellation tests deliberately close sockets with pending responses.
  ensure
    socket.close
  end

  private def reply(socket, type, body)
    socket << "HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    socket.flush
  end
end

private def companion_spec_server
  server = CompanionProxySpecServer.new
  CONFIG.invidious_companion = [Config::CompanionConfig.new(server.url)]
  server
end

private def companion_spec_context(method = "GET", path = "/manifest", body : String? = nil)
  output = IO::Memory.new
  request = HTTP::Request.new(method, path, HTTP::Headers{"Connection" => "keep-alive"}, body)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(output))
  {context, output}
end

private def call_companion_spec_route(method, context)
  case method
  when "GET"     then Invidious::Routes::Companion.get_companion(context)
  when "POST"    then Invidious::Routes::Companion.post_companion(context)
  when "OPTIONS" then Invidious::Routes::Companion.options_companion(context)
  end
end

private def short_companion_spec_timeout
  wrapper = COMPANION_POOL.pool.checkout
  wrapper.client.read_timeout = 50.milliseconds
  COMPANION_POOL.pool.release(wrapper)
end

Spectator.describe "Companion proxy connection safety" do
  before_each do
    COMPANION_POOL.pool.close
    LOGGER.messages.clear
  end

  after_each do
    COMPANION_POOL.pool.close
    CompanionProxySpecServer.close_all
  end

  it "does not reuse the delayed response after both Companion attempts time out" do
    companion_spec_server
    pool = CompanionConnectionPool.new(capacity: 1)
    begin
      expect do
        pool.client do |wrapper|
          wrapper.client.read_timeout = 50.milliseconds
          wrapper.client.get("/slow").body
        end
      end.to raise_error(IO::TimeoutError)

      body = pool.client do |wrapper|
        wrapper.client.read_timeout = 2.seconds
        wrapper.client.get("/manifest").body
      end
      expect(body).to eq("<MPD/>")
    ensure
      pool.pool.close
    end
  end

  it "also invalidates a failed retry in the Youtube connection pool" do
    server = companion_spec_server
    pool = YoutubeConnectionPool.new(server.url, capacity: 1)
    begin
      expect do
        pool.client do |client|
          client.read_timeout = 50.milliseconds
          client.get("/slow").body
        end
      end.to raise_error(IO::TimeoutError)

      body = pool.client do |client|
        client.read_timeout = 2.seconds
        client.get("/manifest").body
      end
      expect(body).to eq("<MPD/>")
    ensure
      pool.pool.close
    end
  end

  it "preserves the default one-retry behavior for buffered Companion calls" do
    companion_spec_server
    attempts = 0
    result = COMPANION_POOL.client do |_wrapper|
      attempts += 1
      raise IO::Error.new("first attempt failed") if attempts == 1
      "ok"
    end
    expect(result).to eq("ok")
    expect(attempts).to eq(2)
  end

  it "allows streaming callers to disable retries" do
    companion_spec_server
    attempts = 0
    expect do
      COMPANION_POOL.client(retry_on_error: false) do |_wrapper|
        attempts += 1
        raise IO::Error.new("stream failed")
      end
    end.to raise_error(IO::Error)
    expect(attempts).to eq(1)
  end

  {% for method in %w[GET POST OPTIONS] %}
    it {{ "returns one explicit gateway error for a failed #{method.id} request" }} do
      method = {{ method }}
      server = companion_spec_server
      short_companion_spec_timeout
      context, output = companion_spec_context(method, "/slow?sig=private-query")
      call_companion_spec_route(method, context)
      response = HTTP::Client::Response.from_io(output.rewind)
      expect(response.status_code).to eq(502)
      expect(response.body).to eq("502 Bad Gateway\n")
      expect(server.requests.size).to eq(1)
      expect(LOGGER.messages.size).to eq(1)
      expect(LOGGER.messages.first).to contain("IO::TimeoutError")
      expect(LOGGER.messages.first).not_to contain("private-query")
    end

    it {{ "still forwards successful #{method.id} responses" }} do
      method = {{ method }}
      server = companion_spec_server
      context, output = companion_spec_context(method, "/manifest", method == "POST" ? "request-body" : nil)
      call_companion_spec_route(method, context)
      context.response.close
      response = HTTP::Client::Response.from_io(output.rewind)
      expect(response.status_code).to eq(200)
      expect(response.body).to eq("<MPD/>")
      expect(response.headers["Content-Type"]).to eq("application/dash+xml")
      expect(server.requests.size).to eq(1)
      expect(server.bodies.first).to eq(method == "POST" ? "request-body" : "")
    end
  {% end %}

  it "does not retry or append a gateway payload after a media response has started" do
    server = companion_spec_server
    short_companion_spec_timeout
    context, output = companion_spec_context("GET", "/partial")
    Invidious::Routes::Companion.get_companion(context)
    wire = output.to_s
    expect(context.response.closed?).to be_true
    expect(context.response.headers["Connection"]).to eq("close")
    expect(server.requests.size).to eq(1)
    expect(wire.scan(/HTTP\/1.1/).size).to eq(1)
    expect(wire).not_to contain("Bad Gateway")
    expect(wire.ends_with?("B" * 65536)).to be_true
  end
end
