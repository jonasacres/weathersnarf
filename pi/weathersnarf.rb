#!/usr/bin/ruby

# listens for tcpdump -X output capturing smartHUB data, fed over a TCP socket
#
# feed me data using a sniff like this from the router
# tcpdump -X host SMARTHUB_IP_ADDRESS and port 80 | nc LOCAL_IP_ADDRESS 10100
# please don't forward me packets that aren't AcuRite smartHUB data, i'm not really tested for that

require 'socket'
require 'cgi'
require 'sqlite3'
require 'json'

def parse_line(line)
  comps = line.strip.split(/\s+/)

  if comps.first =~ /^\d{2}:\d{2}:\d{2}.\d{6}/ then
    {
      type: :start,
      time:comps[0],
      src:comps[2],
      dest:comps[4].gsub(":", ""),
      flags:comps[6][1..-3].split(""),
      seq_start:comps[8].split(":").first.to_i,
      seq_stop:comps[8].split(":").last.to_i,
      length:comps[14].to_i
    }
  else
    {
      type: :data,
      data: comps[1..-2].join("").gsub(/../) { |pair| pair.hex.chr }
    }
  end
end

def log(msg)
  puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S -- ")}" + msg
end

def monitor(client)
  context = { }

  while text = client.gets do
    text.split("\n").each do |line|
      parsed = parse_line(line)
      if parsed[:type] == :start then
        context = { data:"", src:parsed[:src], dest:parsed[:dest], flags:parsed[:flags], length:parsed[:length] }
      else
        context[:data] += parsed[:data]
        if context[:flags].include?("P") && context[:data].length == 256*context[:data][6].ord+context[:data][7].ord + 4 then
          link_offset = 4
          tcp_offset = link_offset + 4*(context[:data][4].ord & 0x0F)
          data_offset = tcp_offset + 4*((context[:data][tcp_offset+12].ord & 0xF0) >> 4)

          yield ({ src:context[:src], dest:context[:dest], data:context[:data][data_offset..-1], flags:context[:flags] })
        elsif context[:flags].include?("F") then
          yield ({ src:context[:src], dest:context[:dest], data:"", flags:context[:flags] })
        end
      end
    end
  end
end

def conn_hash(src, dest)
  src + ">" + dest
end

def process_msg(msg)
  m = msg.match(/GET ([^\x00\s]+[\x00\s])/)
  yield m[1] if m
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
  end

  db
end

def logged_keys
  [ :sensor, :windspeedmph, :winddir, :rainin, :dailyrainin, :humidity, :tempf, :dewptf, :baromin ]
end

def parse_query(query)
  raw = CGI::parse(query.split("?")[1..-1].join("?").strip)
  args = {}
  
  @last ||= {}
  @last[raw["sensor"].first] ||= {}
  last_record = @last[raw["sensor"].first]

  logged_keys.each do |key|
    k = key.to_s
    if raw[k] && raw[k].first then
      last_record[k] = raw[k].first
    end
    args[k] = last_record[k]
  end

  args[:time_since] = Time.now.to_i - (last_record[:last_seen] || 0)
  args[:different] = args != last_record[:last_args]
  last_record[:last_seen] = Time.now.to_i
  last_record[:last_args] = args

  args
end

def record_entry(query)
  args = parse_query(query)
  return unless args[:time_since] >= 60 || args[:different] # only log if it has been at least 60 seconds, or if the data has changed

  db = open_db("weather.db")

  db.execute "INSERT INTO weather (query, time_inserted_epoch, time_inserted_str, #{logged_keys.join(", ")}) values (?, ?, ?, #{logged_keys.map { "?" }.join(", ")})",
    [ query, Time.now.to_i, Time.now.strftime("%Y-%m-%d %H:%M:%S %z") ] + logged_keys.map { |k| args[k.to_s] }

  log "Sensor:#{args["sensor"]} Temp:#{args["tempf"]}F Rain:#{args["dailyrainin"]}\" Wind:#{args["windspeedmph"]}mph Dir:#{args["winddir"]}deg Baro:#{args["baromin"]} Humid:#{args["humidity"]}% Dew:#{args["dewptf"]}F"
end

def run!(port)
  IO.write("/tmp/weathersnarf.pid", Process.pid)
  server = TCPServer.new(port)
  log "Listening on #{port}"
  
  loop do
    client = server.accept
    log "Accepted client: #{client.peeraddr[2]}"

    Thread.new do
      connections = {}
      monitor(client) do |packet|
        h = conn_hash(packet[:src], packet[:dest])
        connections[h] ||= { data:"" }
        connections[h][:data] += packet[:data]

        if packet[:flags].include?("F") then
          process_msg(connections[h][:data]) { |q| record_entry(q) }
          connections.delete(h)
        end
      end

      log "Closed connection to client: #{client.peeraddr[2]}"
    end
  end
end

run!(ARGV.first || 10100)
