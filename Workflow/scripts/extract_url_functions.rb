#!/usr/bin/env ruby

require 'open3'
require 'pathname'
require 'json'

Workflow_name = ENV['alfred_workflow_name']


def get_title_url
  url_title = Open3.capture2(Pathname.pwd.join('get_title_and_url.js').to_path, '--').first.split("\n") # Second dummy argument is to not require shellescaping single argument

  return false if url_title.empty?

  { url: url_title.first, title: url_title.last }
end

def show_options
  clipboard = Open3.capture2('pbpaste').first.strip
  tab_info = get_title_url

  script_filter_items = []

  common_options = {
    subtitle: "Add to WatchList: #{Workflow_name}",
    valid: true
  }

  if tab_info
    tab_options = common_options.clone
    tab_options[:title] = tab_info[:title]
    tab_options[:arg] = tab_info[:url]

    script_filter_items.push(tab_options)
  end

  if clipboard.start_with?('http')
    clipboard_options = common_options.clone
    clipboard_options[:title] = clipboard
    clipboard_options[:arg] = clipboard

    script_filter_items.push(clipboard_options)
  end

  if script_filter_items.empty?
    script_filter_items.push(
      title: 'No URL found',
      subtitle: 'Did not find a URL in the clipboard or a supported browser as the frontmost app',
      valid: false
    )
  end

  puts({ items: script_filter_items }.to_json)
end