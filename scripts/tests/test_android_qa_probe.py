import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_qa_probe import require_observation


class ProbeResultTest(unittest.TestCase):
    def test_android_36_false_ok_is_rejected(self):
        result = (b"java.lang.NoClassDefFoundError: android.test.RepetitiveTest\n"
                  b"OK (1 test)\nINSTRUMENTATION_STATUS: shortMsg=Failed resolution\n"
                  b"INSTRUMENTATION_STATUS_CODE: -1\n")
        with self.assertRaises(RuntimeError):
            require_observation(result, "observed banner tap")

    def test_success_requires_the_invoked_action(self):
        result = (b"observed banner dismiss\r\nINSTRUMENTATION_STATUS_CODE: 0\r\n"
                  b"OK (1 test)\r\nINSTRUMENTATION_STATUS_CODE: -1\r\n")
        require_observation(result, "observed banner dismiss")
        with self.assertRaises(RuntimeError):
            require_observation(result, "observed banner tap")
