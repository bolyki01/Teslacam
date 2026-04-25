#!/usr/bin/env ruby
# Adds the "TeslaCam iPad" target to the Xcode project.
# Shares most sources with macOS but swaps Main.swift for IPadMain.swift.

require 'xcodeproj'

project_path = File.join(__dir__, '..', 'TeslaCam.xcodeproj')
project = Xcodeproj::Project.open(project_path)

# Check if target already exists
if project.targets.any? { |t| t.name == 'TeslaCam iPad' }
  puts "Target 'TeslaCam iPad' already exists. Skipping."
  exit 0
end

mac_target = project.targets.find { |t| t.name == 'TeslaCam' }
abort("Cannot find macOS TeslaCam target") unless mac_target

# Create the iPad target
ipad_target = project.new_target(
  :application,
  'TeslaCam iPad',
  :ios,
  '18.0'
)

# Find source group
teslacam_group = project.main_group.find_subpath('TeslaCam', false)
abort("Cannot find TeslaCam group") unless teslacam_group

# Files to share between both targets (everything except Main.swift and Exporter.swift)
shared_file_names = %w[
  AppState.swift
  ContentView.swift
  Indexer.swift
  MetalRenderer.swift
  MetalShaders.metal
  MetalPlayerView.swift
  MetalPlayerView_iPad.swift
  Models.swift
  NativeExportController.swift
  PlaybackController.swift
  PlatformFileAccess.swift
  TelemetryParser.swift
  Utils.swift
]

# iPad-only entry point
ipad_only_files = %w[IPadMain.swift]

# Add new file references if not already present
new_files = %w[PlatformFileAccess.swift MetalPlayerView_iPad.swift IPadMain.swift TeslaCam_iPad.entitlements]
new_files.each do |fname|
  unless teslacam_group.files.any? { |f| f.display_name == fname }
    file_path = File.join('TeslaCam', fname)
    ref = teslacam_group.new_reference(fname)
    puts "Added file reference: #{fname}"
  end
end

# Add source files to iPad target
all_ipad_sources = shared_file_names + ipad_only_files
all_ipad_sources.each do |fname|
  ref = teslacam_group.files.find { |f| f.display_name == fname }
  if ref
    if fname.end_with?('.metal')
      ipad_target.source_build_phase.add_file_reference(ref)
    else
      ipad_target.source_build_phase.add_file_reference(ref)
    end
    puts "Added to iPad Sources: #{fname}"
  else
    puts "WARNING: Could not find file reference for #{fname}"
  end
end

# Add resources
resources_group = teslacam_group.find_subpath('Resources', false)
if resources_group
  resources_group.files.each do |res|
    ipad_target.resources_build_phase.add_file_reference(res)
    puts "Added to iPad Resources: #{res.display_name}"
  end
end

# Add Assets.xcassets
assets_ref = teslacam_group.files.find { |f| f.display_name == 'Assets.xcassets' }
if assets_ref
  ipad_target.resources_build_phase.add_file_reference(assets_ref)
  puts "Added to iPad Resources: Assets.xcassets"
end

# Configure build settings for iPad
ipad_target.build_configurations.each do |config|
  config.build_settings['SDKROOT'] = 'iphoneos'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '2' # iPad only
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.magrathean.TeslaCam.iPad'
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = '3T84D5XQXL'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'TeslaCam/TeslaCam_iPad.entitlements'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ENABLE_PREVIEWS'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['SWIFT_APPROACHABLE_CONCURRENCY'] = 'YES'
  config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  config.build_settings['SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait'
  config.build_settings['INFOPLIST_KEY_UISupportsDocumentBrowser'] = 'YES'
  config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
  config.build_settings['SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD'] = 'NO'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']

  if config.name == 'Debug'
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf'
    config.build_settings['ENABLE_TESTABILITY'] = 'YES'
  else
    config.build_settings['SWIFT_COMPILATION_MODE'] = 'wholemodule'
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
  end
end

# Also add new files to macOS target's source build phase
%w[PlatformFileAccess.swift].each do |fname|
  ref = teslacam_group.files.find { |f| f.display_name == fname }
  if ref && !mac_target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    mac_target.source_build_phase.add_file_reference(ref)
    puts "Added to macOS Sources: #{fname}"
  end
end

project.save
puts "\nDone. 'TeslaCam iPad' target added successfully."
