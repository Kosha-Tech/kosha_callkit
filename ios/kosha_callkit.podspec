#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint kosha_callkit.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'kosha_callkit'
  s.version          = '2.8.2'
  s.summary          = 'Connectycube Call Kit plugin for flutter.'
  s.description      = <<-DESC
Connectycube Call Kit plugin for flutter.
                       DESC
  s.homepage         = 'https://connectycube.com/'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ConnectyCube' => 'support@connectycube.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '8.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
