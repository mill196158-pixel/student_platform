library subject_diary;

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:ui' as ui;
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // rootBundle
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:lottie/lottie.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/config/yandex_storage_config.dart';
import 'package:student_platform/src/services/s3_client.dart';

part 'models.dart';
part 'repo.dart';
part 'widgets.dart';
part 'screens/quick_note_screen.dart';
part 'screens/photo_conspect_screen.dart';
// серверная реализация репозитория (Supabase + Yandex S3)
part '../../../data/subject_diary_repository_supabase.dart';

// Глобальный флаг для координации realtime между родителем и экраном дня
final ValueNotifier<bool> diaryRealtimeSuspended = ValueNotifier<bool>(false);
