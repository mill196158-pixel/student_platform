/// Shared HTTPS validation corpus (Stage 14.2.3) for student_ui + admin tests.
class SafeHttpsCorpusEntry {
  const SafeHttpsCorpusEntry(this.url, {this.accept = true});

  final String url;
  final bool accept;
}

const kSafeHttpsCorpus = <SafeHttpsCorpusEntry>[
  SafeHttpsCorpusEntry('https://example.com/a'),
  SafeHttpsCorpusEntry('https://sub.example.com/path?q=1'),
  SafeHttpsCorpusEntry('http://example.com/a', accept: false),
  SafeHttpsCorpusEntry('javascript:alert(1)', accept: false),
  SafeHttpsCorpusEntry('data:text/plain,hi', accept: false),
  SafeHttpsCorpusEntry('file:///etc/passwd', accept: false),
  SafeHttpsCorpusEntry('//evil.example', accept: false),
  SafeHttpsCorpusEntry('https://user:pass@example.com', accept: false),
  SafeHttpsCorpusEntry('https:///path-only', accept: false),
  SafeHttpsCorpusEntry('https://', accept: false),
  SafeHttpsCorpusEntry('not-a-url', accept: false),
  SafeHttpsCorpusEntry('https://exam ple.com', accept: false),
];

String safeHttpsCorpusOverlongUrl(int length) {
  const prefix = 'https://example.com/';
  return '$prefix${'a' * (length - prefix.length)}';
}
