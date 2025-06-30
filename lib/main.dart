import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'background_task.dart';



void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  runApp(
    const MaterialApp(
      home: TripLoggerPage(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class TripLoggerPage extends StatefulWidget {
  const TripLoggerPage({super.key});
  @override
  State<TripLoggerPage> createState() => _TripLoggerPageState();
}

class _TripLoggerPageState extends State<TripLoggerPage> {
  Position? _lastPosition;
  StreamSubscription<Position>? _positionStream;
  double _totalDistance = 0.0;
  DateTime? startTime, endTime, selectedDate;
  String? startAddress, endAddress;
  File? selectedExcelFile;
  bool _isTripSaved = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _initForegroundTask();
    _checkLocationPermission();
    _loadLastUsedFile();
    _requestPermission();
  }


  void _initForegroundTask() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'trip_logger_channel_id',
        channelName: 'Trip Logger Background Service',
        channelDescription: 'Tracking your trip in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }


  Future<void> _requestPermission() async {
    await Geolocator.requestPermission();
    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  @pragma('vm:entry-point')
  void startCallback() {
    FlutterForegroundTask.setTaskHandler(TripLoggerTaskHandler());
  }

  Future<void> _loadLastUsedFile() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('last_excel_path');
    if (path != null && File(path).existsSync()) {
      setState(() => selectedExcelFile = File(path));
    }
  }

  Future<void> _pickExcelFile() async {
    if (selectedExcelFile != null) {
      final cont = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Excel file already selected"),
          content: Text("Current file:\n${selectedExcelFile!.path}\n\nDo you want to replace it?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("No")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Yes")),
          ],
        ),
      );
      if (cont != true) return;
    }

    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (result != null) {
      final original = File(result.files.single.path!);
      File copied;
      if (Platform.isAndroid) {
        final name = result.files.single.name;
        final target = File('/storage/emulated/0/Download/$name');
        copied = await original.copy(target.path);
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        final name = result.files.single.name;
        copied = await original.copy('${appDir.path}/$name');
      }
      setState(() => selectedExcelFile = copied);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_excel_path', copied.path);
    }
  }


  Future<bool> _checkLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
        return false;
      }
    }
    return true;
  }

  Future<String> _getAddress(Position pos) async {
    final placemark = (await placemarkFromCoordinates(pos.latitude, pos.longitude)).first;
    final street = placemark.street ?? "";
    final name = placemark.name ?? "";
    String formatted = street.isNotEmpty ? street : name;

    final apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
    final url = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=${pos.latitude},${pos.longitude}&radius=50&key=$apiKey';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List;

        for (var place in results) {
          final types = (place['types'] as List).cast<String>();

          if (types.contains('lodging') || types.contains('gas_station')) {
            return place['name']; // Hotel vagy benzinkút neve
          }
        }
      }
    } catch (e) {
      print("Google Places API error: $e");
    }

    return formatted.replaceAll(RegExp(r'\bStrada\b', caseSensitive: false), 'str.').trim();
  }

  Future<void> _startTrip() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Trip Logger Active',
      notificationText: 'Tracking your location...',
      callback: startCallback,
    );
    final hasPermission = await _checkLocationPermission();
    if (!hasPermission) return;

    setState(() {
      _totalDistance = 0;
      _lastPosition = null;

    });

    _positionStream = Geolocator.getPositionStream(locationSettings: const LocationSettings(distanceFilter: 1)).listen((pos) {
      if (_lastPosition != null) {
        final d = Geolocator.distanceBetween(
          _lastPosition!.latitude, _lastPosition!.longitude,
          pos.latitude, pos.longitude,
        );
        _totalDistance += d;
      }
      _lastPosition = pos;
    });

    final pos = await Geolocator.getCurrentPosition();
    startAddress = await _getAddress(pos);
    startTime = DateTime.now();
    setState(() {});
  }

  Future<void> _endTrip() async {
    await FlutterForegroundTask.stopService();
    _positionStream?.cancel();
    final hasPermission = await _checkLocationPermission();
    if (!hasPermission) return;

    final pos = await Geolocator.getCurrentPosition();
    endAddress = await _getAddress(pos);
    endTime = DateTime.now();
    setState(() {});
  }

  Future<void> _saveToExcel({required bool saveAsNew}) async {
    if (selectedExcelFile == null || selectedDate == null) return;

    if (_isTripSaved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This trip has already been saved!")),
      );
      return;
    }

    try {
      final bytes = selectedExcelFile!.readAsBytesSync();
      final excel = Excel.decodeBytes(bytes);
      final sheetName = DateFormat('dd.MM.yyyy').format(selectedDate!);
      final sheet = excel[sheetName];


      for (int i = 7; i <= 25; i++) {
        final isEmpty = List.generate(5, (col) {
          final val = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: i)).value;
          return val == null || val.toString().trim().isEmpty;
        }).every((e) => e);

        if (isEmpty) {
          for (int col = 0; col <= 4; col++) {
            final idx = CellIndex.indexByColumnRow(columnIndex: col, rowIndex: i);
            final oldStyle = sheet.cell(idx).cellStyle;

            final value = switch (col) {
              0 => TextCellValue(startAddress ?? ""),
              1 => TextCellValue(DateFormat('HH:mm').format(startTime!)),
              2 => TextCellValue(endAddress ?? ""),
              3 => TextCellValue(DateFormat('HH:mm').format(endTime!)),
              4 => TextCellValue((_totalDistance / 1000).toStringAsFixed(2)),
              _ => TextCellValue(""),
            };

            sheet.updateCell(idx, value, cellStyle: oldStyle);
          }
          break;
        }
      }

      final data = excel.encode();
      if (data == null) return;

      final downloadsPath = '/storage/emulated/0/Download';
      final originalName = p.basenameWithoutExtension(selectedExcelFile!.path);
      final extension = p.extension(selectedExcelFile!.path);
      final newFileName = saveAsNew ? "${originalName}_1$extension" : "$originalName$extension";
      final path = p.join(downloadsPath, newFileName);

      await File(path).writeAsBytes(data);
      setState(() => _isTripSaved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Saved to:: $path")),
      );
      print("Saved to:: $path");
    } catch (e) {
      print("Save error: $e");
    }
  }

  void _reset() {
    setState(() {
      _lastPosition = null;
      _totalDistance = 0;
      startTime = endTime = null;
      startAddress = endAddress = null;
      _isTripSaved = false;
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Roova"),
        centerTitle: true,
      ),
      body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCard(
              title: "Excel file",
              children: [
                ElevatedButton(onPressed: _pickExcelFile, child: const Text("Pick Excel File")),
                if (selectedExcelFile != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      p.basename(selectedExcelFile!.path),
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                Text(
                  selectedDate == null
                      ? "No date selected"
                      : "Sheet: ${DateFormat('dd.MM.yyyy').format(selectedDate!)}",
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) setState(() => selectedDate = d);
                      },
                      child: const Text("Select Date"),
                    ),
                    ElevatedButton(
                      onPressed: () => setState(() => selectedDate = DateTime.now()),
                      child: const Text("Set Today"),
                    ),
                    ElevatedButton(
                      onPressed: () => setState(() => selectedDate = null),
                      child: const Text("Clear Date"),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildCard(
              title: "Tracking",
              children: [
                ElevatedButton(onPressed: _startTrip, child: const Text("Start Trip")),
                ElevatedButton(onPressed: _endTrip, child: const Text("End Trip")),
                ElevatedButton(onPressed: _reset, child: const Text("Reset")),
              ],
            ),
            const SizedBox(height: 16),
            if (startTime != null || endTime != null)
              _buildCard(
                title: "Trip Details",
                children: [
                  if (startTime != null && startAddress != null) ...[
                    const Text("Start:", style: TextStyle(fontWeight: FontWeight.bold)),
                    Text("Time: ${DateFormat('HH:mm').format(startTime!)}"),
                    Text("Address: $startAddress"),
                    const SizedBox(height: 12),
                  ],
                  if (endTime != null && endAddress != null) ...[
                    const Text("End:", style: TextStyle(fontWeight: FontWeight.bold)),
                    Text("Time: ${DateFormat('HH:mm').format(endTime!)}"),
                    Text("Address: $endAddress"),
                    Text("Distance: ${(_totalDistance / 1000).toStringAsFixed(2)} km"),
                  ],
                ],
              ),
            const SizedBox(height: 16),
            _buildCard(
              title: "Save",
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _saveToExcel(saveAsNew: false),
                        child: const Text("Save to original"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _saveToExcel(saveAsNew: true),
                        child: const Text("Save to copy"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    );
  }

// Helper method
  Widget _buildCard({required String title, required List<Widget> children}) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

}
