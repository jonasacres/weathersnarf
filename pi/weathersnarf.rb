#!/usr/bin/ruby

require 'socket'
require 'sqlite3'
require 'json'

$http_keystore_url = "http://owl:11000" # comment out to disable http-keystore use
accumulator = ""

def logged_keys
  [ :sensor, :windspeedmph, :winddir, :rainin, :dailyrainin, :humidity, :tempf, :dewptf, :baromin ]
end

def log(msg)
  puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S -- ")}" + msg
end

def parse_query(raw)
  args = {}
  @last ||= {}
  @last[raw["sensor"]] ||= {}
  last_record = @last[raw["sensor"]]

  logged_keys.each do |key|
    k = key.to_s
    last_record[k] = raw[k] if raw[k]
    args[k] = last_record[k]
  end

  args[:time_since] = Time.now.to_i - (last_record[:last_seen] || 0)
  args[:different] = args != last_record[:last_args]
  last_record[:last_seen] = Time.now.to_i
  last_record[:last_args] = args

  args
end

def send_http_keystore(args)
  return unless $http_keystore_url

  Thread.new do
    url = File.join($http_keystore_url, "sensor-#{args["sensor"]}")
    IO.popen "curl -X POST -d @- #{url} 1>/dev/null 2>&1", 'r+' do |io|
      io.puts args.to_json
    end
  end
end

def record_entry(query)
  args = parse_query(query)
  return unless args[:time_since] >= 60 || args[:different] # only log if it has been at least 60 seconds, or if the data has changed
  logged_keys.each { |key| return unless args[key.to_s] }

  args.merge!({ "query" => "", "time_inserted_epoch" => Time.now.to_i, "time_inserted_str" => Time.now.strftime("%Y-%m-%d %H:%M:%S %z") })
  insert_keys = args.keys.select { |k| k.is_a?(String) }
  send_http_keystore(args)

  db = open_db("weather.db")
  log "Inserting keys: #{insert_keys.map { |k| "#{k} = #{args[k.to_s]}" }.join(", ")}"
  log "INSERT INTO weather (#{insert_keys.join(", ")}) values (#{insert_keys.map { "?" }.join(", ")})"
  log insert_keys.map { |k| args[k.to_s] }.count.to_s

  db.execute "INSERT INTO weather (#{insert_keys.join(", ")}) values (#{insert_keys.map { "?" }.join(", ")})", insert_keys.map { |k| args[k.to_s] }

  log "Sensor:#{args["sensor"]} Temp:#{args["tempf"]}F Rain:#{args["dailyrainin"]}\" Wind:#{args["windspeedmph"]}mph Dir:#{args["winddir"]}deg Baro:#{args["baromin"]} Humid:#{args["humidity"]}% Dew:#{args["dewptf"]}F"
end

def open_db(path)
  db_existed = File.exists?(path)
  db = SQLite3::Database.new path

  unless db_existed then
    db.execute <<-SQL
      create table weather (
        record_id integer primary key autoincrement,
        time_inserted_epoch integer,
        time_inserted_str varchar(32),
        
        sensor varchar(32),
        windspeedmph integer,
        winddir integer,
        rainin real,
        dailyrainin real,
        humidity integer,
        tempf real,
        dewptf integer,
        baromin real,

        query text
      );
    SQL

    db.execute <<-SQL
      create index time_index on weather (time_inserted_epoch)
    SQL

    log "Created database #{weather.db}"
  end

  db
end

def monitor(client)
  accumulator = ""

  while text = client.gets do
    text.split("\n").each do |line|
      next if line.start_with?("T ")
      accumulator += line

      if m = accumulator.match(/GET \/weatherstation\/updateweatherstation\?([^ ]+) HTTP/) then
        h = {}
        m[1].split("&").map { |pair| pair.split("=") }.each { |p| h[p[0]] = p[1] }
        accumulator = ""
        yield(h)
      end
    end
  end
end

def run!(port)
  IO.write("/tmp/weathersnarf.pid", Process.pid)
  server = TCPServer.new(port)
  log "Listening on #{port}"
  
  loop do
    client = server.accept
    log "Accepted client: #{client.peeraddr[2]}"

    Thread.new do
      begin
        connections = {}
        monitor(client) do |request|
          record_entry(request)
        end

        log "Closed connection to client: #{client.peeraddr[2]}"
      rescue Exception => exc
        log "Caught exception handling #{client.peeraddr[2]}: #{exc.class} #{exc.to_s}"
        puts exc.backtrace.join("\n")
      end
    end
  end
end

run!(ARGV.first ? ARGV.first.to_i : 10100)
