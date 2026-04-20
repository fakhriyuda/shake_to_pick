import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DecisionMakerApp());
}

class DecisionMakerApp extends StatelessWidget {
  const DecisionMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shake to Decide',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.tealAccent,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Colors.tealAccent,
          secondary: Colors.yellowAccent,
        ),
        fontFamily: 'Inter',
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _hasStarted = false;
  bool _isShaking = false;
  bool _isTriggered = false;
  String? _resultText;
  
  double _shakeIntensityY = 0.0;
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  
  late ConfettiController _confettiController;
  
  late AudioPlayer _shakeAudioPlayer;
  late AudioPlayer _prankAudioPlayer;

  // Options Sets
  Map<String, List<String>> _savedSets = {
    "Lunch Menu": ["Pizza", "Burger", "Sushi", "Salad", "Tacos"],
    "Truth or Dare": ["Truth", "Dare", "Neither"],
  };
  String _currentSetName = "Lunch Menu";

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(seconds: 3));
    _shakeAudioPlayer = AudioPlayer();
    _prankAudioPlayer = AudioPlayer();
    
    // Set the audio context for playing simultaneously and ignoring silent mode on iOS
    AudioPlayer.global.setAudioContext(AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: {
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.assistanceSonification,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    ));

    _initPrefs();
  }
  
  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString('savedSets');
    if (savedData != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(savedData);
        setState(() {
          _savedSets = decoded.map((key, value) => MapEntry(key, List<String>.from(value)));
          if (!_savedSets.containsKey(_currentSetName) && _savedSets.isNotEmpty) {
            _currentSetName = _savedSets.keys.first;
          }
        });
      } catch (e) {
        // If malformed json, stick to defaults
      }
    } else {
      _savePrefs(); // Save defaults
    }
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedSets', jsonEncode(_savedSets));
  }

  void _startApp() async {
    setState(() {
      _hasStarted = true;
    });

    // Request permissions/unlock audio on Web/iOS via user interaction.
    // In a real scenario 'shaking_sound.mp3' and 'prank_sound.mp3' must be provided in your asset dir.
    try {
      await _shakeAudioPlayer.setSourceAsset('audio/shaking_sound.mp3');
      await _shakeAudioPlayer.setReleaseMode(ReleaseMode.loop);
      await _prankAudioPlayer.setSourceAsset('audio/prank_sound.mp3');
    } catch (e) {
      // Audio files might be missing. That's fine, we continue execution without crashing.
    }
    
    // Start accelerometer
    _listenToSensors();
  }
  
  void _listenToSensors() {
    // using userAccelerometer to ignore gravity
    _accelSubscription = userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50), // Responsive update speed
    ).listen((UserAccelerometerEvent event) {
      if (_isTriggered) return;

      final double intensity = event.y.abs();
      
      setState(() {
        _shakeIntensityY = event.y;
      });

      if (intensity > 3.0) {
        if (!_isShaking) {
          _isShaking = true;
          try {
            _shakeAudioPlayer.resume(); // Start looping shake sound
          } catch (_) {}
        }
      } else {
        if (_isShaking && intensity < 1.5) {
          _isShaking = false;
          try {
            _shakeAudioPlayer.pause();
          } catch (_) {}
        }
      }

      // Threshold to trigger the result
      if (intensity > 15.0) {
        _triggerResult();
      }
    }, onError: (dynamic error) {
      // Device might not have accelerometer
      print("Error listening to sensors: $error");
    });
  }

  void _triggerResult() async {
    setState(() {
      _isTriggered = true;
      _isShaking = false;
    });
    
    _accelSubscription?.cancel();
    try {
      await _shakeAudioPlayer.stop();
    } catch (_) {}

    // The Prank Element
    HapticFeedback.heavyImpact();
    
    try {
      await _prankAudioPlayer.setVolume(1.0);
      await _prankAudioPlayer.resume();
    } catch (_) {}

    // Select random item
    final random = Random();
    final currentList = _savedSets[_currentSetName] ?? ["No options!"];
    final selected = currentList.isNotEmpty 
        ? currentList[random.nextInt(currentList.length)] 
        : "Empty List!";
    
    setState(() {
      _resultText = selected;
    });

    _confettiController.play();
  }

  void _reset() {
    setState(() {
      _isTriggered = false;
      _resultText = null;
      _shakeIntensityY = 0.0;
    });
    _listenToSensors();
  }  

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _confettiController.dispose();
    _shakeAudioPlayer.dispose();
    _prankAudioPlayer.dispose();
    super.dispose();
  }

  // A simple dialog to manage sets
  void _openSetManager() {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Manage Sets', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: _savedSets.keys.map((setName) {
                return ListTile(
                  title: Text(setName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  trailing: _savedSets.length > 1 ? IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.yellowAccent),
                    onPressed: () {
                      setState(() {
                        _savedSets.remove(setName);
                        if (_currentSetName == setName) {
                          _currentSetName = _savedSets.keys.first;
                        }
                        _savePrefs();
                      });
                      Navigator.pop(context);
                      _openSetManager(); // refresh dialog
                    },
                  ) : null,
                  onTap: () {
                    setState(() {
                      _currentSetName = setName;
                    });
                    Navigator.pop(context);
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('Close', style: TextStyle(color: Colors.tealAccent))
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasStarted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.tealAccent.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.touch_app, size: 80, color: Colors.tealAccent),
              ),
              const SizedBox(height: 32),
              const Text(
                'Decision Maker',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Shake the device to decide!',
                style: TextStyle(fontSize: 18, color: Colors.white70),
              ),
              const SizedBox(height: 56),
              ElevatedButton(
                onPressed: _startApp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: const Color(0xFF0F172A),
                  elevation: 10,
                  shadowColor: Colors.tealAccent.withOpacity(0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text('TAP TO START', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              ),
              const SizedBox(height: 24),
              const Text(
                'Requires Audio & Motion Sensor Access\nEnable prompts if blocked by iOS Safari.', 
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentSetName, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0F172A), fontSize: 22)),
        backgroundColor: Colors.tealAccent,
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_open, color: Color(0xFF0F172A), size: 28),
            onPressed: _openSetManager,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          // Background visual changes based on intensity
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            color: _isShaking ? Colors.tealAccent.withOpacity(0.15) : Colors.transparent,
          ),
          
          if (!_isTriggered) ...[
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('SHAKE ME', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white24, letterSpacing: 2.0)),
                const SizedBox(height: 60),
                // Stage 2 Visuals
                Transform.translate(
                  offset: Offset(0, _shakeIntensityY * -20), // Move opposite to Y accel for natural feel
                  child: Container(
                    width: 70,
                    height: 220,
                    decoration: BoxDecoration(
                      color: Colors.tealAccent,
                      borderRadius: BorderRadius.circular(40),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.tealAccent.withOpacity(0.5),
                          blurRadius: 30,
                          spreadRadius: 5,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.yellowAccent,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.yellowAccent.withOpacity(0.8),
                              blurRadius: 10,
                              spreadRadius: 2,
                            )
                          ]
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Stage 3 Results
          if (_isTriggered) ...[
            ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [Colors.tealAccent, Colors.yellowAccent, Colors.white, Colors.cyanAccent],
              emissionFrequency: 0.1,
              numberOfParticles: 50,
              gravity: 0.2,
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 50),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: Colors.yellowAccent,
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.yellowAccent.withOpacity(0.4),
                        blurRadius: 40,
                        spreadRadius: 10,
                        offset: const Offset(0, 20),
                      )
                    ]
                  ),
                  child: Center(
                    child: Text(
                      _resultText ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        height: 1.0,
                        letterSpacing: -1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 80),
                ElevatedButton(
                  onPressed: _reset,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.tealAccent,
                    foregroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text('SHAKE AGAIN', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                )
              ],
            ),
          ]
        ],
      ),
    );
  }
}
