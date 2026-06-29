import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const HelloApp());

class HelloApp extends StatelessWidget {
  const HelloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Hello Toolchain",
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.amber),
      home: const HelloPage(),
    );
  }
}

class HelloPage extends StatefulWidget {
  const HelloPage({super.key});

  @override
  State<HelloPage> createState() => _HelloPageState();
}

class _HelloPageState extends State<HelloPage> {
  String _message = "Press the button to call the Go backend.";
  bool _loading = false;

  Future<void> _callBackend() async {
    setState(() => _loading = true);

    const apiBase = String.fromEnvironment(
      "API_BASE_URL",
      defaultValue: "http://localhost:8080",
    );

    try {
      final res = await http.get(Uri.parse("$apiBase/api/hello"));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() => _message = body["message"] as String);
    } catch (e) {
      setState(() => _message = "Request failed: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Hello Toolchain")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_message, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            _loading
                ? const CircularProgressIndicator()
                : FilledButton(
                    onPressed: _callBackend,
                    child: const Text("Call the Go backend"),
                  ),
          ],
        ),
      ),
    );
  }
}
