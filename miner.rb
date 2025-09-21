require 'socket'
require 'digest/sha1'
require 'net/http'
require 'json'
require 'thread'
require 'yaml'  # Thêm để đọc YAML

# Đọc config từ YAML
begin
  config = YAML.load_file('config.yml')
  USERNAME = config['username'] || 'your_username_here'
  MINING_KEY = config['mining_key']  # Có thể null
  RIG_IDENTIFIER = config['rig_identifier'] || 'TermuxMiner'
  DIFFICULTY = config['difficulty'] || 'LOW'
  THREADS = config['thread_count'] || 2
  puts "Đọc config thành công từ config.yml"
rescue => e
  puts "Lỗi đọc config.yml: #{e.message}. Sử dụng default."
  USERNAME = 'your_username_here'
  MINING_KEY = nil
  RIG_IDENTIFIER = 'TermuxMiner'
  DIFFICULTY = 'LOW'
  THREADS = 2
end

$shares = { accepted: 0, rejected: 0, blocks: 0 }
$thread_hashrates = Array.new(THREADS, 0.0)
$multithread_id = rand(10000..99999)  # ID ngẫu nhiên

def fetch_pool
  uri = URI('https://server.duinocoin.com/getPool')
  response = Net::HTTP.get(uri)
  pool = JSON.parse(response)
  if pool['success']
    { host: pool['ip'], port: pool['port'].to_i }
  else
    { host: 'server.duinocoin.com', port: 2813 }
  end
rescue => e
  puts "Lỗi lấy pool: #{e.message}. Sử dụng fallback."
  { host: 'server.duinocoin.com', port: 2813 }
end

def format_hashrate(hashrate)
  if hashrate >= 1e9
    "#{(hashrate / 1e9).round(2)} GH/s"
  elsif hashrate >= 1e6
    "#{(hashrate / 1e6).round(2)} MH/s"
  elsif hashrate >= 1e3
    "#{(hashrate / 1e3).round(2)} kH/s"
  else
    "#{hashrate.round(2)} H/s"
  end
end

def solve(base, target_hex, diff)
  target = [target_hex].pack('H*')
  start_time = Time.now

  (0..(diff * 100)).each do |nonce|
    hash = Digest::SHA1.digest(base + nonce.to_s)
    return { nonce: nonce, elapsed_us: ((Time.now - start_time) * 1e6).to_i } if hash == target
  end
  nil
end

def mine(thread_id, host, port)
  loop do
    begin
      socket = TCPSocket.new(host, port)
      puts "[Thread #{thread_id}] Kết nối thành công đến #{host}:#{port}"

      version = socket.gets&.strip
      puts "[Thread #{thread_id}] Connected (server v#{version})" if version

      loop do
        key_part = MINING_KEY ? ",#{MINING_KEY}" : ''
        socket.puts "JOB,#{USERNAME},#{DIFFICULTY}#{key_part}"

        jobline = socket.gets&.strip
        break unless jobline
        parts = jobline.split(',')
        next if parts.size != 3

        base = parts[0]
        target_hex = parts[1]
        diff = parts[2].to_i

        sol = solve(base, target_hex, diff)
        if sol
          elapsed = sol[:elapsed_us] / 1e6.to_f
          elapsed = 0.001 if elapsed.zero?
          hashrate = (sol[:nonce].to_f + 1) / elapsed
          $thread_hashrates[thread_id] = hashrate

          msg = "#{sol[:nonce]},#{hashrate.round(2)},RubyMiner,#{RIG_IDENTIFIER},#{$multithread_id}\n"
          socket.puts msg

          feedback = socket.gets&.strip
          case feedback
          when 'GOOD'
            $shares[:accepted] += 1
            puts "[Thread #{thread_id}] ✅ Share accepted | #{format_hashrate(hashrate)} | Accepted: #{$shares[:accepted]}"
          when /^BAD,/
            $shares[:rejected] += 1
            puts "[Thread #{thread_id}] ❌ Rejected: #{feedback[4..]} | Rejected: #{$shares[:rejected]}"
          when 'BLOCK'
            $shares[:blocks] += 1
            puts "[Thread #{thread_id}] ⛓️ New block | Blocks: #{$shares[:blocks]}"
          else
            puts "[Thread #{thread_id}] ℹ️ Feedback: #{feedback}"
          end

          total_shares = $shares[:accepted] + $shares[:rejected]
          if total_shares % 10 == 0 && total_shares > 0
            puts "[Thread #{thread_id}] 📊 Shares: #{$shares[:accepted]} good / #{$shares[:rejected]} bad"
          end
        else
          puts "[Thread #{thread_id}] Job không giải được trong giới hạn."
        end
      end
    rescue => e
      puts "[Thread #{thread_id}] Lỗi: #{e.message}. Kết nối lại sau 5 giây..."
      sleep 5
    end
  end
end

# Bắt đầu
pool = fetch_pool
puts "Sử dụng pool: #{pool[:host]}:#{pool[:port]}"

threads = THREADS.times.map do |i|
  Thread.new { mine(i, pool[:host], pool[:port]) }
end

Thread.new do
  loop do
    sleep 60
    overall_hashrate = $thread_hashrates.inject(0.0, :+) .round(2)
    puts "Tổng hashrate: #{format_hashrate(overall_hashrate)}, Accepted: #{$shares[:accepted]}, Rejected: #{$shares[:rejected]}, Blocks: #{$shares[:blocks]}"
  end
end

threads.each(&:join)