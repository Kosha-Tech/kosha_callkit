// Minimal harness app. Its only job is to make CI compile the plugin's
// native iOS (Swift) and Android (Kotlin) code via `flutter build ios/apk`,
// and to keep a real reference to the plugin's Dart API so `flutter analyze`
// covers it.
import 'package:flutter/material.dart';
import 'package:kosha_callkit/connectycube_flutter_call_kit.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  Future<void> _configure() async {
    ConnectycubeFlutterCallKit.instance.init(
      ringtone: 'ringtone',
      localizedName: 'KoshaX reminder',
    );
    await ConnectycubeFlutterCallKit.instance
        .updateConfig(localizedName: 'KoshaX reminder');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: _configure,
            child: const Text('configure call kit'),
          ),
        ),
      ),
    );
  }
}
