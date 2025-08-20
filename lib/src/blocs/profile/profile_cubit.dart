import 'package:flutter_bloc/flutter_bloc.dart';
import '../../models/demo_user.dart';

class ProfileCubit extends Cubit<DemoUser> {
  ProfileCubit() : super(DemoUser.demo());

  void update({
    String? firstName,
    String? lastName,
    String? university,
    String? group,
    String? status,
    String? avatarPath,
  }) {
    emit(state.copyWith(
      firstName: firstName,
      lastName: lastName,
      university: university,
      group: group,
      status: status,
      avatarPath: avatarPath,
    ));
  }
}

// синглтон для демо
final ProfileCubit profileCubit = ProfileCubit();
