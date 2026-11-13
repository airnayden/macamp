#!/usr/bin/env bash
set -euo pipefail

# Use an installed runtime and device instead of assuming a runner model name.
xcrun simctl list devices available -j | ruby -rjson -e '
  devices = JSON.parse(STDIN.read).fetch("devices")
  runtimes = devices.keys.grep(/\.iOS-/).sort_by do |runtime|
    runtime.split(".iOS-", 2).last.split("-").map(&:to_i)
  end
  iphone = runtimes.reverse_each.flat_map { |runtime| devices.fetch(runtime) }
    .find { |device| device.fetch("name").start_with?("iPhone") }
  abort "No available iPhone simulator. Install an iOS Simulator runtime and create an iPhone device." unless iphone
  puts iphone.fetch("udid")
'
