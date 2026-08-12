Pod::Spec.new do |s|
  s.name         = "Starscream"
  s.version      = "5.0.0"
  s.summary      = "An RFC 6455 WebSocket library in Swift."
  s.homepage     = "https://github.com/daltoniam/Starscream"
  s.license      = 'Apache License, Version 2.0'
  s.author       = {'Dalton Cherry' => 'http://daltoniam.com', 'Austin Cherry' => 'http://austincherry.me'}
  s.source       = { :git => 'https://github.com/daltoniam/Starscream.git',  :tag => "#{s.version}"}
  s.social_media_url = 'http://twitter.com/daltoniam'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '10.15'
  s.tvos.deployment_target = '13.0'
  s.watchos.deployment_target = '6.0'
  s.source_files = 'Sources/**/*.swift'
  s.swift_version = '6.0'
  s.pod_target_xcconfig = {
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
  }
  s.resource_bundles = {
    'Starscream_Privacy' => ['Sources/PrivacyInfo.xcprivacy'],
  }
end
