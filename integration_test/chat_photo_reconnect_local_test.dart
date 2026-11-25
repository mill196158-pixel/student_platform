import 'package:integration_test/integration_test.dart';
import '../test/chat_photo_reconnect_local_test.dart'
    show registerPhotoReconnectTest;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerPhotoReconnectTest();
}
