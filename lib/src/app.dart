import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'ui/authentication/screens/change_password_screen.dart';
import 'ui/authentication/screens/login_screen.dart';
import 'ui/navigation/navigation_screen.dart';

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  Session? _session;
  bool _mustChangePassword = false;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;
    _loadPasswordFlag();
    Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      setState(() => _session = event.session);
      _loadPasswordFlag();
    });
  }

  Future<void> _loadPasswordFlag() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _mustChangePassword = false);
      return;
    }

    final row = await Supabase.instance.client
        .from('users')
        .select('must_change_password')
        .eq('id', userId)
        .maybeSingle();

    if (mounted) {
      setState(
          () => _mustChangePassword = row?['must_change_password'] == true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      routes: {
        '/change-password': (_) => const ChangePasswordScreen(),
        '/home': (_) => const NavigationScreen(),
        '/login': (_) => LoginScreen(toggleView: () {}),
      },
      home: _session == null
          ? LoginScreen(toggleView: () {})
          : _mustChangePassword
              ? const ChangePasswordScreen()
              : const NavigationScreen(),
    );
  }
}
