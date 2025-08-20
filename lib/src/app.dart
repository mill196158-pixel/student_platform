import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'ui/authentication/screens/login_screen.dart';
import 'ui/navigation/navigation_screen.dart';

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  Session? _session;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;
    Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      setState(() => _session = event.session);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _session == null
          ? const LoginScreen()
          : const NavigationScreen(),
    );
  }
}
