  static Future<void> init() async {
    if (_inited) return;
    await Supabase.initialize(
      url: const String.fromEnvironment('https://gwdanmwluhrcfxbnplwd.supabase.co'),
      anonKey: const String.fromEnvironment('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd3ZGFubXdsdWhyY2Z4Ym5wbHdkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUyNjM1MTgsImV4cCI6MjA3MDgzOTUxOH0.tBZ7b_FyOxPWiqkFQf1OIh9c6hJ7Fm2eHyjsDjoBoSA'),
      debug: false,
    );
    _inited = true;
  }

  static SupabaseClient get client => Supabase.instance.client;
}

}
