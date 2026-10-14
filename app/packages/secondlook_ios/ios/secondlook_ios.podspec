Pod::Spec.new do |s|
  s.name             = 'secondlook_ios'
  s.version          = '1.0.0'
  s.summary          = 'Second Look iOS bridge: on-device scam engine via JavaScriptCore.'
  s.homepage         = 'https://example.com/secondlook'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Second Look' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.resources        = ['Assets/secondlook_engine.js']
  s.dependency 'Flutter'
  s.frameworks       = 'JavaScriptCore', 'CallKit', 'LocalAuthentication', 'CryptoKit', 'Security', 'Vision', 'ImageIO', 'AVFoundation'
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
