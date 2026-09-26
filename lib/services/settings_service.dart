import 'package:flutter/foundation.dart';

import '../data/repositories.dart';

class SettingsService extends ChangeNotifier {
  SettingsService(this._repo, this._value);

  final SettingsRepository _repo;
  AppSettings _value;

  AppSettings get value => _value;

  void update(AppSettings Function(AppSettings) f) {
    _value = f(_value);
    notifyListeners();
    _repo.save(_value);
  }
}
