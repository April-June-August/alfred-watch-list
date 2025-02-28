#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require 'open3'

Lists_dir = ENV['lists_dir'].empty? ? ENV['alfred_workflow_data'] : ENV['lists_dir']
Lists_file = "#{Lists_dir}/watchlist.json".freeze
# Maximum_watched = Integer(ENV['maximum_watched'])
Quick_playlist = File.join(ENV['alfred_workflow_cache'], 'quick_playlist.txt')
Move_when_adding = !ENV['move_on_add'].empty?
Prepend_new = ENV['prepend_new_item'] == '1'
Trash_on_watched = ENV['trash_on_watched'] == '1'
Top_on_play = ENV['top_on_play'] == '1'
Prefer_action_url = ENV['prefer_action_url'] == '1'

Bundle_id_of_this_workflow = ENV['alfred_workflow_bundleid']
Failed_list = File.join(Lists_dir, 'Failed.txt')

FileUtils.mkpath(Lists_dir) unless Dir.exist?(Lists_dir)
FileUtils.mkpath(File.dirname(Quick_playlist)) unless Dir.exist?(File.dirname(Quick_playlist))
File.write(Lists_file, { towatch: [], watched: [] }.to_json) unless File.exist?(Lists_file)

def convert_dakuten(chars)
  return unless chars.is_a?(String)
  chars.gsub(/\u309B/, "\u3099")
       .gsub(/\u309C/, "\u309A")
       .unicode_normalize(:nfc)
end

def ordinal(number)
  abs_number = number.to_i.abs
  # Special case for 11, 12, 13
  if (11..13).include?(abs_number % 100)
    "#{number}th"
  else
    case abs_number % 10
    when 1 then "#{number}st"
    when 2 then "#{number}nd"
    when 3 then "#{number}rd"
    else        "#{number}th"
    end
  end
end

def already_exist(path_or_url)
  all_lists = read_lists
  # true if its url or path in either towatch or watched list
  all_lists['towatch'].any? { |item| item['path'] == path_or_url } || all_lists['towatch'].any? { |item| item['url'] == path_or_url } || all_lists['watched'].any? { |item| item['path'] == path_or_url } || all_lists['watched'].any? { |item| item['url'] == path_or_url }
end

def move_to_dir(path, target_dir)
  path_name = File.basename(path)
  target_path = File.join(target_dir, path_name)

  if File.dirname(path) == target_dir
    warn 'Path is already at target directory'
  elsif File.exist?(target_path)
    error('Can’t move because another target with the same name already exists')
  else
    File.rename(path, target_path)
  end

  target_path
end

def add_local_to_watchlist(path, id = random_hex, allow_move = true)
  require_audiovisual(path)

  target_path = Move_when_adding && allow_move ? move_to_dir(path, File.expand_path(ENV['move_on_add'])) : path

  all_lists = read_lists
  if already_exist(target_path)
    existing_name = File.basename(target_path)
    notification("Already in watchlist: “#{existing_name}”", 'Sosumi')
    return
  end

  if File.file?(target_path)
    add_file_to_watchlist(target_path, id)
    notification("Added as file: “#{target_path}”", 'Funk')
  elsif File.directory?(target_path)
    add_dir_to_watchlist(target_path, id)
    notification("Added as folder: “#{target_path}”", 'Funk')
  else
    error('Not a valid path')
  end
end

def add_file_to_watchlist(file_path, id = random_hex)
  name = File.basename(file_path, File.extname(file_path))

  duration_machine = duration_in_seconds(file_path)
  duration_human = seconds_to_hms(duration_machine)

  size_machine = Open3.capture2('du', file_path).first.to_i
  size_human = Open3.capture2('du', '-h', file_path).first.slice(/[^\t]*/).strip

  size_duration_ratio = size_machine / duration_machine

  url = Open3.capture2('mdls', '-raw', '-name', 'kMDItemWhereFroms', file_path).first.split("\n")[1].strip.delete('"') rescue nil

  hash = {
    'id' => id,
    'type' => 'file',
    'name' => name,
    'path' => file_path,
    'count' => nil,
    'url' => url,
    'duration' => {
      'machine' => duration_machine,
      'human' => duration_human
    },
    'size' => {
      'machine' => size_machine,
      'human' => size_human
    },
    'ratio' => size_duration_ratio
  }

  add_to_list(hash, 'towatch', Prepend_new)
end

def add_dir_to_watchlist(dir_path, id = random_hex)
  all_lists = read_lists
  if already_exist(dir_path)
    existing_name = File.basename(dir_path)
    notification("Series already in watchlist: “#{existing_name}”", 'Sosumi')
    return
  end

  name = File.basename(dir_path)

  hash = {
    'id' => id,
    'type' => 'series',
    'name' => name,
    'path' => dir_path,
    'count' => 'counting files…',
    'url' => nil,
    'duration' => {
      'machine' => nil,
      'human' => 'getting duration…'
    },
    'size' => {
      'machine' => nil,
      'human' => 'calculating size…'
    },
    'ratio' => nil
  }

  add_to_list(hash, 'towatch', Prepend_new)
  update_series(id)
end

def update_series(id)
  all_lists = read_lists
  item_index = find_index(id, 'towatch', all_lists)
  item = all_lists['towatch'][item_index]

  dir_path = item['path']
  audiovisual_files = list_audiovisual_files(dir_path)
  first_file = audiovisual_files.first
  count = audiovisual_files.count

  duration_machine = duration_in_seconds(first_file)
  duration_human = seconds_to_hms(duration_machine)

  size_machine = Open3.capture2('du', first_file).first.to_i
  size_human = Open3.capture2('du', '-h', first_file).first.slice(/[^\t]*/).strip

  size_duration_ratio = size_machine / duration_machine

  item['count'] = count
  item['duration']['machine'] = duration_machine
  item['duration']['human'] = duration_human
  item['size']['machine'] = size_machine
  item['size']['human'] = size_human
  item['ratio'] = size_duration_ratio

  write_lists(all_lists)
end

def process_single_url(url, playlist, id)
  playlist_flag = playlist ? '--yes-playlist' : '--no-playlist'

  stdout, stderr, status = Open3.capture3('/opt/homebrew/bin/yt-dlp', '--get-filename', '-o', '%(title)s|||||%(channel)s', playlist_flag, url)
  if status.success?
    all_title_and_channel = stdout.split("\n")
  else
    notification("❌️ ERROR: “#{stderr}”", 'Basso')
    File.open(Failed_list, "a") do |file|
      file.puts "#{url} “failed when extracting titles and channel” #{stderr}\n"
    end
    return ""
  end

  # copy the url if failed
  # IO.popen('pbcopy', 'w') { |f| f << url } if all_names.empty?

  # command succeeded but result empty
  if all_title_and_channel.empty?
    # record a failed list for failed items
    File.open(Failed_list, "a") do |file|
      notification("❌️ ERROR: “succeeded but result empty”", 'Basso')
      file.puts "#{url} “succeeded but result empty”\n"
    end
    return ""
  end

  # original logic is to just error out
  # error "Could not add url as stream: #{url}" if all_title_and_channel.empty?

  # If playlist, get the playlist name instead of the the name of the first item

  # title_and_channel = all_title_and_channel.count > 1 ? Open3.capture2('/opt/homebrew/bin/yt-dlp', '--yes-playlist', '--get-filename', '--output', '%(playlist)s|||||%(channel)s', url).first.split("\n").first : all_title_and_channel[0]

  if all_title_and_channel.count > 1
    stdout, stderr, status = Open3.capture3('/opt/homebrew/bin/yt-dlp', '--yes-playlist', '--get-filename', '--output', '%(playlist)s|||||%(channel)s', url)

    if status.success?
      title_and_channel = stdout.split("\n").first
    else
      notification("❌️ ERROR: “failed when extracting playlist name and channel”", 'Basso')

      File.open(Failed_list, "a") do |file|
        file.puts "#{url} “failed when extracting playlist name and channel” #{stderr}\n"
      end

      return ""
    end
  else
    title_and_channel = all_title_and_channel[0]
  end

  title, channel = title_and_channel.split('|||||').first(2)

  # durations = Open3.capture2('/opt/homebrew/bin/yt-dlp', '--get-duration', playlist_flag, url).first.split("\n")

  stdout, stderr, status = Open3.capture3('/opt/homebrew/bin/yt-dlp', '--get-duration', playlist_flag, url)

  if status.success?
    durations = stdout.split("\n")
  else
    notification("❌️ ERROR: “failed when extracting duration”", 'Basso')

    File.open(Failed_list, "a") do |file|
      file.puts "#{url} “failed when extracting duration” #{stderr}\n"
    end

    return ""
  end

  count = durations.count > 1 ? durations.count : nil

  duration_machine = durations.map { |d| colons_to_seconds(d) }.inject(0, :+)
  duration_human = seconds_to_hms(duration_machine)

  stream_hash = {
    'id' => id,
    'type' => 'stream',
    'name' => title,
    'channel' => channel,
    'path' => nil,
    'count' => count,
    'url' => url,
    'duration' => {
      'machine' => duration_machine,
      'human' => duration_human
    },
    'size' => {
      'machine' => nil,
      'human' => nil
    },
    'ratio' => nil
  }

  add_to_list(stream_hash, 'towatch', Prepend_new)
  title
end

def add_url_to_watchlist(url, playlist = false, id = random_hex)
  # Split the provided text into non-empty lines.
  urls = url.split("\n").map(&:strip).reject(&:empty?)
  added_count = 0
  skipped_account = 0
  failed_account = 0
  total = urls.size
  # notification("Found #{total} #{total == 1 ? 'link' : 'links'}!", 'Frog')

  if urls.size > 1
    urls.each_with_index do |single_url, idx|
      all_lists = read_lists
      if already_exist(single_url)
        # sleep 0.1
        # notification("Skipped duplicate URL: “#{single_url}”", '')
        skipped_account += 1
        next
      end

      # Generate a unique id for each URL in a multi-line input.
      title = process_single_url(single_url, playlist, random_hex)

      # failed urls returns empty names
      failed_account += 1 if title.empty?
      next if title.empty?

      added_count += 1
      notification("#{ordinal(idx + 1)} of #{total} items added as stream: “#{title}”", '')
    end

    # If it's the last item, include the sound.
    sleep 1
    notification("✅️ Process complete. #{added_count} added, #{failed_account} failed, #{skipped_account} skipped in #{total}.", 'Funk')

  else
    single_url = url.strip
    all_lists = read_lists
    if already_exist(single_url)
      notification("Already in watchlist: “#{single_url}”", 'Sosumi')
      return
    end

    name = process_single_url(single_url, playlist, id)
    # Single URL is the only (and thus last) item so include the sound.
    
    # condition to guard name since we now return even if failed
    error "Could not add url as stream: #{single_url}" if name.empty?
    notification("Added as stream: “#{name}”", 'Funk')
  end
end

def is_a_match_of_keyword(item, keyword)
  normalized_keyword = convert_dakuten(keyword.strip).downcase
  item_name = item['name']
  normalized_name = convert_dakuten(item_name).downcase

  item_channel = item['channel'] || ''
  normalized_channel = convert_dakuten(item_channel).downcase

  normalized_name.include?(normalized_keyword) || normalized_channel.include?(normalized_keyword)
end

def display_towatch(sort = nil, keyword)
  item_list = read_lists['towatch']

  if item_list.empty?
    puts({ items: [{ title: 'Play (p)', subtitle: 'Nothing to watch', valid: false }] }.to_json)
    exit 0
  end

  script_filter_items = []

  hash_to_output =
    case sort
    when 'duration_ascending'
      item_list.sort_by { |content| content['duration']['machine'] }
    when 'duration_descending'
      item_list.sort_by { |content| content['duration']['machine'] }.reverse
    when 'size_ascending'
      item_list.sort_by { |content| content['size']['machine'] || Float::INFINITY }
    when 'size_descending'
      item_list.sort_by { |content| content['size']['machine'] || -Float::INFINITY }.reverse
    when 'best_ratio'
      item_list.sort_by { |content| content['ratio'] || -Float::INFINITY }.reverse
    else
      item_list
    end

  hash_to_output.each do |details|
    unless keyword.to_s.strip.empty?
      next unless is_a_match_of_keyword(details, keyword)
    end

    item_count = details['count'].nil? ? '' : "(#{details['count']}) 𐄁 "

    # Common values
    item = {
      title: details['name'],
      arg: details['id'],
      mods: {},
      action: {}
    }

    # Common modifications
    case details['type']
    when 'file', 'series' # Not a stream
      item[:subtitle] = "#{item_count}#{details['duration']['human']} 𐄁 #{details['size']['human']} 𐄁 #{details['path']}"
    end

    item[:mods][:ctrl] = details['url'].nil? ? { subtitle: 'This item has no origin url', valid: false } : { subtitle: details['url'], arg: details['url'] }

    # Specific modifications
    case details['type']
    when 'file'
      item[:quicklookurl] = details['path']
      item[:mods][:alt] = { subtitle: 'This modifier is only available on series and streams', valid: false }
      item[:action][:auto] = Prefer_action_url && !details['url'].nil? ? details['url'] : details['path']
    when 'stream'
      item[:subtitle] = "≈ #{item_count}#{details['duration']['human']}#{details['channel'].nil? ? '' : ' 𐄁 '}#{details['channel'] || ''} 𐄁 #{details['url']}"
      item[:quicklookurl] = details['url']
      item[:mods][:alt] = { subtitle: 'Download stream' }
      item[:mods][:ctrl] = { subtitle: 'Open in default browser', arg: details['url']}
      item[:action][:url] = details['url']
    when 'series'
      item[:mods][:alt] = { subtitle: 'Rescan series' }
      item[:action][:file] = details['path']
    end

    script_filter_items.push(item)
  end

  if script_filter_items.empty?
    puts({ items: [{ title: 'No items Found', subtitle: "Nothing found with the query #{keyword}", valid: false }] }.to_json)
  else
    puts({ items: script_filter_items, skipKnowledge: true }.to_json)
  end
end

def display_watched(keyword)
  item_list = read_lists['watched']

  if item_list.empty?
    puts({ items: [{ title: 'Mark unwatched (u)', subtitle: 'You have no watched items', valid: false }] }.to_json)
    exit 0
  end

  script_filter_items = []

  item_list.each do |details|
    unless keyword.to_s.strip.empty?
      next unless is_a_match_of_keyword(details, keyword)
    end

    # Common values
    item = {
      title: details['name'],
      arg: details['id'],
      icon: {
        path: "./icon_gray.png"
      },
      mods: {},
      action: {}
    }

    # Modifications
    if details['url'].nil?
      item[:subtitle] = details['path']
      item[:mods][:ctrl] = { subtitle: 'This item has no origin url', valid: false }
      item[:mods][:alt] = { subtitle: 'This item has no origin url', valid: false }
    else
      item[:subtitle] = details['type'] == 'stream' ? "#{details['channel'] || ''}#{details['channel'].nil? ? '' : ' 𐄁 '}#{details['url']}" : "#{details['url']} 𐄁 #{details['path']}"
      item[:quicklookurl] = details['url']
      item[:mods][:ctrl] = { subtitle: 'Open link in default browser', arg: details['url'] }
      item[:mods][:alt] = { subtitle: 'Copy link to clipboard', arg: details['url'] }
      item[:action][:url] = details['url']
    end

    script_filter_items.push(item)
  end

  if script_filter_items.empty?
    puts({ items: [{ title: 'No items Found', subtitle: "Nothing found with the query #{keyword}", valid: false }] }.to_json)
  else
    puts({ items: script_filter_items, skipKnowledge: true }.to_json)
  end
end

def play(id, send_to_watched = true)
  Top_on_play ? switch_list(id, 'towatch', 'towatch', true) : switch_list(id, 'towatch', 'towatch', false)

  all_lists = read_lists
  item_index = find_index(id, 'towatch', all_lists)
  item = all_lists['towatch'][item_index]

  case item['type']
  when 'file'
    return unless play_item('file', item['path'])

    mark_watched(id) if send_to_watched == true
  when 'stream'
    return unless play_item('stream', item['url'])

    mark_watched(id) if send_to_watched == true
  when 'series'
    if !File.exist?(item['path']) && send_to_watched == true
      mark_watched(id)
      error 'Marking as watched since the directory no longer exists'
    end

    first_file = list_audiovisual_files(item['path']).first

    return unless play_item('file', first_file)
    return if send_to_watched == false

    # If there are no more audiovisual files in the directory in addition to the one we just watched, trash the whole directory, else trash just the watched file
    if list_audiovisual_files(item['path']).reject { |e| e == first_file }.empty?
      mark_watched(id) if send_to_watched == true
    else
      trash(first_file) if Trash_on_watched
      update_series(id)
    end
  end
end

# By checking for and running the CLI of certain players instead of the app bundle, we get access to the exit status. That way, in the 'play' method, even if the file were to be marked as watched we do not do it unless it was a success.
# This means we can configure our video player to not exit successfully on certain conditions and have greater granularity with WatchList.
def play_item(type, path)
  return true if path.nil? || type != 'stream' && !File.exist?(path) # If non-stream item does not exist, exit successfully so it can still be marked as watched

  # The 'split' together with 'last' serves to try to pick the last installed version, in case more than one is found (multiple versions in Homebrew Cellar, for example)
  video_player = lambda {
    mpv_homebrew_apple_silicon = '/opt/homebrew/bin/mpv'
    return [mpv_homebrew_apple_silicon, '--no-terminal'] if File.executable?(mpv_homebrew_apple_silicon)

    mpv_homebrew_intel = '/usr/local/bin/mpv'
    return [mpv_homebrew_intel, '--no-terminal'] if File.executable?(mpv_homebrew_intel)

    mpv_app = Open3.capture2('mdfind', 'kMDItemCFBundleIdentifier', '=', 'io.mpv').first.strip.split("\n").last
    return [mpv_app + '/Contents/MacOS/mpv', '--no-terminal'] if mpv_app

    iina = Open3.capture2('mdfind', 'kMDItemCFBundleIdentifier', '=', 'com.colliderli.iina').first.strip.split("\n").last
    return iina + '/Contents/MacOS/IINA' if iina

    vlc = Open3.capture2('mdfind', 'kMDItemCFBundleIdentifier', '=', 'org.videolan.vlc').first.strip.split("\n").last
    return vlc + '/Contents/MacOS/VLC' if vlc

    'other'
  }.call

  error('To play a stream you need mpv, iina, or vlc') if video_player == 'other' && type == 'stream'

  video_player == 'other' ? system('open', '-W', path) : Open3.capture2(*video_player, path)[1].success?
end

def mark_watched(id)
  switch_list(id, 'towatch', 'watched', true)

  all_lists = read_lists
  item_index = find_index(id, 'watched', all_lists)
  item = all_lists['watched'][item_index]

  # original code removes item from watched list if more that x.
  # all_lists['watched'] = all_lists['watched'].first(Maximum_watched)

  # I'm keeping it forever.
  write_lists(all_lists)

  if item['type'] == 'stream'
    system('/usr/bin/afplay', '/System/Library/Sounds/Purr.aiff')
    return
  end

  # when item is not stream and don't have to be move to the trash
  system('/usr/bin/afplay', '/System/Library/Sounds/Purr.aiff') unless Trash_on_watched

  # Trash
  return unless Trash_on_watched

  trashed_name = trash(item['path'])
  return if File.basename(item['path']) == trashed_name

  # If name had to change to send to Trash, update list with new name
  item['trashed_name'] = trashed_name
  write_lists(all_lists)
end

def mark_unwatched(id)
  switch_list(id, 'watched', 'towatch', true)

  if !Trash_on_watched
    system('/usr/bin/afplay', '/System/Library/Sounds/Purr.aiff')
    return
  end

  # Try to recover trashed file

  all_lists = read_lists
  item_index = find_index(id, 'towatch', all_lists)
  item = all_lists['towatch'][item_index]

  if item['type'] == 'stream'
    system('/usr/bin/afplay', '/System/Library/Sounds/Purr.aiff')
    return
  end

  if item['trashed_name']
    trashed_path = File.join(ENV['HOME'], '.Trash', item['trashed_name'])
    item.delete('trashed_name')
    write_lists(all_lists)
  else
    trashed_path = File.join(ENV['HOME'], '.Trash', File.basename(item['path']))
  end

  error('Could not find item in Trash') unless File.exist?(trashed_path)
  error('Could not recover from Trash because another item exists at original location') if File.exist?(item['path'])

  File.rename(trashed_path, item['path'])
  system('/usr/bin/afplay', '/System/Library/Sounds/Purr.aiff')
end

def download_stream(id)
  all_lists = read_lists
  item_index = find_index(id, 'towatch', all_lists)
  item = all_lists['towatch'][item_index]
  url = item['url']

  mark_watched(id)
  puts url
end

def read_towatch_order
  print read_lists['towatch'].map { |item| "#{item['id']}: #{item['name']}" }.join("\n")
end

def write_towatch_order(text_order)
  all_lists = read_lists

  new_items = text_order.strip.split("\n").each_with_object([]) { |item, new_array|
    id_name = item.split(':')
    id = id_name[0].strip
    name = id_name[1..-1].join(':').strip

    item_index = find_index(id, 'towatch', all_lists)
    item = all_lists['towatch'][item_index]

    error "Unrecognised id: #{id}" if item_index.nil?
    item['name'] = name

    new_array.push(item)
  }

  all_lists['towatch'] = new_items
  write_lists(all_lists)
end

def verify_quick_playlist(minutes_threshold = 3)
  return false unless File.exist?(Quick_playlist)

  if (Time.now - File.mtime(Quick_playlist)) / 60 > minutes_threshold
    File.delete(Quick_playlist)
    return false
  end

  true
end

def add_to_quick_playlist(id)
  verify_quick_playlist
  File.write(Quick_playlist, "#{id}\n", mode: 'a')
  system('/usr/bin/afplay', '/System/Library/Sounds/Frog.aiff')
end

def play_quick_playlist
  return false unless verify_quick_playlist

  ids = File.readlines(Quick_playlist, chomp: true)
  File.delete(Quick_playlist)

  ids.each do |id|
    system('osascript', '-l', 'JavaScript', '-e', "Application('com.runningwithcrayons.Alfred').runTrigger('play_id', { inWorkflow: '#{Bundle_id_of_this_workflow}', withArgument: '#{id}' })")
    system('/usr/bin/afplay', '/System/Library/Sounds/Tink.aiff')
  end
end

def random_hex
  require 'securerandom'
  SecureRandom.hex(6)
end

def colons_to_seconds(duration_colons)
  duration_colons.split(':').map(&:to_i).inject(0) { |a, b| a * 60 + b }
end

def duration_in_seconds(file_path)
  Open3.capture2('ffprobe', '-loglevel', 'quiet', '-output_format', 'csv=p=0', '-show_entries', 'format=duration', file_path).first.to_i
end

def seconds_to_hms(total_seconds)
  return '[Unable to Get Duration]' if total_seconds.zero? # Can happen with yt-dlp's generic extractor (e.g. when adding direct link to an MP4)

  seconds = total_seconds % 60
  minutes = (total_seconds / 60) % 60
  hours = total_seconds / (60 * 60)

  duration_array = [hours, minutes, seconds]
  duration_array.shift while duration_array[0].zero? # Remove leading '0' time segments
  duration_array.join(':').sub(/$/, 's').sub(/(.*):/, '\1m ').sub(/(.*):/, '\1h ')
end

def audiovisual_file?(path)
  Open3.capture2('mdls', '-name', 'kMDItemContentTypeTree', path).first.include?('public.audiovisual-content')
end

def list_audiovisual_files(dir_path)
  escaped_path = dir_path.gsub(/([\*\?\[\]{}\\])/, '\\\\\1')
  Dir.glob("#{escaped_path}/**/*").map(&:downcase).sort.select { |e| audiovisual_file?(e) }
end

def require_audiovisual(path)
  if File.file?(path)
    return if audiovisual_file?(path)

    error('Is not an audiovisual file')
  elsif File.directory?(path)
    return unless list_audiovisual_files(path).first.nil?

    error('Directory has no audiovisual content')
  else
    error('Not a valid path')
  end
end

def read_lists(lists_file = Lists_file)
  JSON.parse(File.read(lists_file))
end

def write_lists(new_lists, lists_file = Lists_file)
  File.write(lists_file, JSON.pretty_generate(new_lists))
end

def add_to_list(new_hash, list, prepending)
  all_lists = read_lists
  all_lists[list] = prepending ? [new_hash].concat(all_lists[list]) : all_lists[list].concat([new_hash])
  write_lists(all_lists)
end

def find_index(id, list, all_lists)
  all_lists[list].index { |item| item['id'] == id }
end

def delete_from_list(id, list)
  all_lists = read_lists
  item_index = find_index(id, list, all_lists)
  item = all_lists[list][item_index]
  all_lists[list].delete(item)
  write_lists(all_lists)
end

def switch_list(id, origin_list, target_list, to_top_of_list)
  all_lists = read_lists
  item_index = find_index(id, origin_list, all_lists)

  # Detect if an item no longer exists before trying to move. Fix for cases where the same item is chosen a second time before having finished playing.
  error 'Item no longer exists' if item_index.nil?

  item = all_lists[origin_list][item_index]
  delete_from_list(id, origin_list)
  add_to_list(item, target_list, to_top_of_list)
end

def trash(path)
  Open3.capture2('osascript', '-l', 'JavaScript', '-e', 'function run(argv) { return Application("Finder").delete(Path(argv[0])).name() }', path).first.strip if File.exist?(path)
end

def notification(message, sound = '')
  system("#{Dir.pwd}/notificator", '--message', message, '--title', ENV['alfred_workflow_name'], '--sound', sound)
end

def error(message)
  notification(message, 'Sosumi')
  abort(message)
end
