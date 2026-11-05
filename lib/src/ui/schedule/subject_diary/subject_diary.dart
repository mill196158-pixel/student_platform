library subject_diary;

import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import '../../shared/workspace_page_header.dart';
import 'package:flutter/services.dart'; // rootBundle
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:lottie/lottie.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart' as crypto;
import '../../../services/file_service.dart';
import '../../../services/chat_file_access.dart';

part 'models.dart';
part 'repo.dart';
part 'widgets.dart';
part 'screens/quick_note_screen.dart';
part 'screens/photo_conspect_screen.dart';
// серверная реализация репозитория (Supabase + Yandex S3)
part '../../../data/subject_diary_repository_supabase.dart';

// Глобальный флаг для координации realtime между родителем и экраном дня
final ValueNotifier<bool> diaryRealtimeSuspended = ValueNotifier<bool>(false);
