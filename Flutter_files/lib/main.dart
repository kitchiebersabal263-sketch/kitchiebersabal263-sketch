import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

import 'dart:developer' as devtools;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    devtools.log("Firebase initialized successfully");
  } catch (e) {
    devtools.log("Error initializing Firebase: $e");
  }
  runApp(const MyApp());
}

// App Colors
class AppColors {
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF12121A);
  static const Color card = Color(0xFF1A1A25);
  static const Color neonCyan = Color(0xFF00F5FF);
  static const Color neonPurple = Color(0xFF8B5CF6);
  static const Color neonPink = Color(0xFFEC4899);
  static const Color neonGreen = Color(0xFF10B981);
  static const Color neonOrange = Color(0xFFF59E0B);
  static const Color neonYellow = Color(0xFFFACC15);
  static const Color danger = Color(0xFFEF4444);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9CA3AF);
  
  static const List<Color> chartColors = [
    neonCyan,
    neonPurple,
    neonPink,
    neonGreen,
    neonOrange,
    neonYellow,
    Color(0xFF06B6D4),
    Color(0xFFA855F7),
    Color(0xFFF472B6),
    Color(0xFF34D399),
  ];
}

// Detection History Item Model - now includes ALL class predictions
class DetectionItem {
  final String imagePath;
  final String topLabel;
  final double topConfidence;
  final DateTime timestamp;
  final bool isUnknown;
  final Map<String, double> allPredictions; // All class predictions
  final String? firestoreId; // Firestore document ID for deletion

  DetectionItem({
    required this.imagePath,
    required this.topLabel,
    required this.topConfidence,
    required this.timestamp,
    required this.allPredictions,
    this.isUnknown = false,
    this.firestoreId,
  });
}

// Global list for history
List<DetectionItem> detectionHistory = [];
List<String> knownClassLabels = [];

// Global callback for history updates
VoidCallback? onHistoryChanged;

// Version counter to force rebuilds
int historyVersion = 0;

// Function to delete a scan from Firestore (local removal is done optimistically)
Future<bool> deleteScanFromFirestore(DetectionItem item) async {
  // Delete from Firestore
  if (item.firestoreId != null && item.firestoreId!.isNotEmpty) {
    try {
      final firestore = FirebaseFirestore.instance;
      await firestore.collection('scans').doc(item.firestoreId).delete();
      devtools.log("Scan deleted from Firestore: ${item.firestoreId}");
      return true;
    } catch (e) {
      devtools.log("Error deleting from Firestore: $e");
      return false;
    }
  }
  
  return true;
}

// Function to load history from Firestore
Future<void> loadHistoryFromFirestore() async {
  try {
    final firestore = FirebaseFirestore.instance;
    final querySnapshot = await firestore
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .get();
    
    detectionHistory.clear();
    
    for (var doc in querySnapshot.docs) {
      final data = doc.data();
      try {
        // Convert Firestore data to DetectionItem
        if (data['timestamp'] == null) {
          devtools.log("Document ${doc.id} missing timestamp, skipping");
          continue;
        }
        
        final timestamp = (data['timestamp'] as Timestamp).toDate();
        
        // Safely parse allPredictions
        Map<String, double> allPredictions = {};
        if (data['allPredictions'] != null && data['allPredictions'] is Map) {
          try {
            allPredictions = Map<String, double>.from(
              (data['allPredictions'] as Map).map(
                (key, value) => MapEntry(
                  key.toString(), 
                  (value is num) ? value.toDouble() : 0.0
                ),
              ),
            );
          } catch (e) {
            devtools.log("Error parsing allPredictions for ${doc.id}: $e");
            allPredictions = {};
          }
        }
        
        detectionHistory.add(
          DetectionItem(
            imagePath: data['imagePath']?.toString() ?? '',
            topLabel: data['topLabel']?.toString() ?? 'Unknown',
            topConfidence: (data['topConfidence'] as num?)?.toDouble() ?? 0.0,
            timestamp: timestamp,
            isUnknown: data['isUnknown'] as bool? ?? false,
            allPredictions: allPredictions,
            firestoreId: doc.id, // Store Firestore document ID
          ),
        );
      } catch (e) {
        devtools.log("Error parsing document ${doc.id}: $e");
      }
    }
    
    devtools.log("Loaded ${detectionHistory.length} scans from Firestore");
    
    // Increment version to force rebuilds
    historyVersion++;
    
    // Notify listeners after loading
    onHistoryChanged?.call();
  } catch (e) {
    devtools.log("Error loading history from Firestore: $e");
    // Continue with empty history if Firestore fails
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Knife Detector X',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.background,
        textTheme: GoogleFonts.orbitronTextTheme(
          ThemeData.dark().textTheme,
        ),
        colorScheme: const ColorScheme.dark(
          primary: AppColors.neonCyan,
          secondary: AppColors.neonPurple,
          surface: AppColors.surface,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// Animated Particle Background
class ParticleBackground extends StatefulWidget {
  final Widget child;
  const ParticleBackground({super.key, required this.child});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<Particle> particles = [];
  final int particleCount = 50;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    
    for (int i = 0; i < particleCount; i++) {
      particles.add(Particle());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: ParticlePainter(particles, _controller.value),
              size: Size.infinite,
            );
          },
        ),
        widget.child,
      ],
    );
  }
}

class Particle {
  double x = math.Random().nextDouble();
  double y = math.Random().nextDouble();
  double speed = math.Random().nextDouble() * 0.02 + 0.005;
  double size = math.Random().nextDouble() * 3 + 1;
  Color color = [
    AppColors.neonCyan.withOpacity(0.3),
    AppColors.neonPurple.withOpacity(0.3),
    AppColors.neonPink.withOpacity(0.2),
  ][math.Random().nextInt(3)];
}

class ParticlePainter extends CustomPainter {
  final List<Particle> particles;
  final double animationValue;

  ParticlePainter(this.particles, this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    for (var particle in particles) {
      final paint = Paint()
        ..color = particle.color
        ..style = PaintingStyle.fill;
      
      double newY = (particle.y + animationValue * particle.speed * 50) % 1.0;
      
      canvas.drawCircle(
        Offset(particle.x * size.width, newY * size.height),
        particle.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Glassmorphism Container
class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final BorderRadius? borderRadius;
  final Color? borderColor;
  final double? blur;

  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.borderColor,
    this.blur,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur ?? 10, sigmaY: blur ?? 10),
        child: Container(
          padding: padding ?? const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.1),
                Colors.white.withOpacity(0.05),
              ],
            ),
            borderRadius: borderRadius ?? BorderRadius.circular(20),
            border: Border.all(
              color: borderColor ?? AppColors.neonCyan.withOpacity(0.2),
              width: 1.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// Neon Glow Box
class NeonGlowBox extends StatelessWidget {
  final Widget child;
  final Color glowColor;
  final double intensity;
  final BorderRadius? borderRadius;

  const NeonGlowBox({
    super.key,
    required this.child,
    this.glowColor = AppColors.neonCyan,
    this.intensity = 0.5,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius ?? BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: glowColor.withOpacity(intensity * 0.6),
            blurRadius: 20,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: glowColor.withOpacity(intensity * 0.3),
            blurRadius: 40,
            spreadRadius: 5,
          ),
        ],
      ),
      child: child,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    // Set global callback
    onHistoryChanged = _onHistoryChanged;
    _loadHistory();
  }

  @override
  void dispose() {
    // Clear global callback
    onHistoryChanged = null;
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoadingHistory = true;
    });
    await loadHistoryFromFirestore();
    setState(() {
      _isLoadingHistory = false;
    });
  }

  void _onHistoryUpdate() {
    setState(() {});
  }

  void _onHistoryChanged() {
    // Force rebuild of all screens when history changes
    if (mounted) {
      setState(() {
        // Force rebuild by incrementing a dummy state
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild screens list every time to ensure fresh widgets
    final List<Widget> screens = [
      MyHomePage(key: ValueKey('home_$historyVersion'), onHistoryUpdate: _onHistoryUpdate),
      AnalyticsPage(key: ValueKey('analytics_$historyVersion')),
      LogsPage(key: ValueKey('logs_$historyVersion')),
    ];

    return Scaffold(
      body: ParticleBackground(
        child: screens[_currentIndex],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.95),
        border: Border(
          top: BorderSide(
            color: AppColors.neonCyan.withOpacity(0.3),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.neonCyan.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(0, Icons.document_scanner_rounded, 'Scan'),
              _buildNavItem(1, Icons.analytics_outlined, 'Analytics'),
              _buildNavItem(2, Icons.list_alt_rounded, 'Logs'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _currentIndex = index;
          // Force UI update when switching tabs
          // The screens will check for updates themselves via didChangeDependencies
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
                  colors: [
                    AppColors.neonCyan.withOpacity(0.2),
                    AppColors.neonPurple.withOpacity(0.2),
                  ],
                )
              : null,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: AppColors.neonCyan.withOpacity(0.5))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? AppColors.neonCyan : AppColors.textSecondary,
              size: 26,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.orbitron(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? AppColors.neonCyan : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== HOME PAGE (SCAN) ====================
class MyHomePage extends StatefulWidget {
  final VoidCallback onHistoryUpdate;

  const MyHomePage({super.key, required this.onHistoryUpdate});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with TickerProviderStateMixin {
  File? filePath;
  String label = '';
  double confidence = 0.0;
  bool isLoading = false;
  bool isUnknown = false;
  Map<String, double> allPredictions = {};
  late AnimationController _pulseController;
  late AnimationController _rotationController;
  late Animation<double> _pulseAnimation;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isProcessing = false; // Prevent concurrent processing

  @override
  void initState() {
    super.initState();
    _tfLteInit();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    _interpreter?.close();
    super.dispose();
  }

  Future<void> _tfLteInit() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model_unquant.tflite');
      devtools.log("Model loaded successfully");
      
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      _labels = labelsData
          .split('\n')
          .map((label) => label.replaceAll(RegExp(r'^\d+\s*'), '').trim())
          .where((label) => label.isNotEmpty)
          .toList();
      knownClassLabels = List<String>.from(_labels);
      devtools.log("Labels loaded: $_labels");
    } catch (e) {
      devtools.log("Error loading model or labels: $e");
    }
  }

  Float32List _preprocessImage(img.Image image, int inputSize) {
    final resizedImage = img.copyResize(image, width: inputSize, height: inputSize);
    final inputBuffer = Float32List(1 * inputSize * inputSize * 3);
    int pixelIndex = 0;
    
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resizedImage.getPixel(x, y);
        inputBuffer[pixelIndex++] = pixel.r / 255.0;
        inputBuffer[pixelIndex++] = pixel.g / 255.0;
        inputBuffer[pixelIndex++] = pixel.b / 255.0;
      }
    }
    
    return inputBuffer;
  }


  Future<void> _addToHistory(String imagePath, String detectedLabel, double conf, bool unknown, Map<String, double> predictions) async {
    final timestamp = DateTime.now();
    String? firestoreId;
    
    // Save to Firestore first to get document ID
    try {
      final firestore = FirebaseFirestore.instance;
      final docRef = await firestore.collection('scans').add({
        'topLabel': detectedLabel,
        'topConfidence': conf,
        'isUnknown': unknown,
        'allPredictions': predictions.map((key, value) => MapEntry(key, value)),
        'timestamp': Timestamp.fromDate(timestamp),
        'imagePath': imagePath, // Note: This is local path. For cloud storage, you'd need to upload the image first
      });
      firestoreId = docRef.id;
      devtools.log("Scan saved to Firestore successfully with ID: $firestoreId");
    } catch (e) {
      devtools.log("Error saving to Firestore: $e");
      // Continue even if Firestore save fails
    }
    
    // Save to local history with Firestore ID
    detectionHistory.insert(
      0,
      DetectionItem(
        imagePath: imagePath,
        topLabel: detectedLabel,
        topConfidence: conf,
        timestamp: timestamp,
        isUnknown: unknown,
        allPredictions: predictions,
        firestoreId: firestoreId,
      ),
    );
    
    // Increment version to force rebuilds
    historyVersion++;
    
    // Notify listeners
    widget.onHistoryUpdate();
    onHistoryChanged?.call();
  }

  Future<void> _processImage(ImageSource source) async {
    // Prevent concurrent processing
    if (_isProcessing) {
      devtools.log("Image processing already in progress, ignoring request");
      return;
    }
    
    // Reset processing flag at start to ensure it's always reset
    _isProcessing = true;
    
    try {
      
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        imageQuality: 75, // Reduced from 85 for better performance
        maxWidth: 1280, // Reduced from 1920 for faster processing
        maxHeight: 1280,
      );

      if (image == null) {
        _isProcessing = false;
        return;
      }

      var imageMap = File(image.path);
      
      // Validate image file exists and is readable
      if (!await imageMap.exists()) {
        devtools.log("Image file does not exist: ${image.path}");
        setState(() {
          isLoading = false;
          label = 'FILE NOT FOUND';
          isUnknown = true;
        });
        _isProcessing = false;
        return;
      }

      setState(() {
        filePath = imageMap;
        isLoading = true;
        label = '';
        confidence = 0.0;
        isUnknown = false;
        allPredictions = {};
      });

      if (_interpreter == null) {
        devtools.log("Interpreter not initialized");
        setState(() {
          isLoading = false;
          label = 'MODEL NOT LOADED';
          isUnknown = true;
          confidence = 0.0;
        });
        await _addToHistory(image.path, 'Error - Model not loaded', 0.0, true, {});
        _isProcessing = false;
        return;
      }

      final imageBytes = await image.readAsBytes();
      
      // Validate image size (prevent memory issues with very large images)
      const maxImageSize = 10 * 1024 * 1024; // 10MB
      if (imageBytes.length > maxImageSize) {
        devtools.log("Image too large: ${imageBytes.length} bytes");
        setState(() {
          isLoading = false;
          label = 'IMAGE TOO LARGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }
      
      final decodedImage = img.decodeImage(imageBytes);
      
      if (decodedImage == null) {
        devtools.log("Failed to decode image");
        setState(() {
          isLoading = false;
          label = 'INVALID IMAGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }
      
      // Validate decoded image dimensions
      if (decodedImage.width <= 0 || decodedImage.height <= 0) {
        devtools.log("Invalid image dimensions: ${decodedImage.width}x${decodedImage.height}");
        setState(() {
          isLoading = false;
          label = 'INVALID IMAGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }

      final inputShape = _interpreter!.getInputTensor(0).shape;
      if (inputShape.length < 2) {
        throw Exception("Invalid input tensor shape: $inputShape");
      }
      final inputSize = inputShape[1];
      if (inputSize <= 0) {
        throw Exception("Invalid input size: $inputSize");
      }
      
      final inputBuffer = _preprocessImage(decodedImage, inputSize);
      // Convert Float32List to nested list format expected by tflite_flutter
      // Shape: [1, inputSize, inputSize, 3]
      // More efficient: create nested structure directly from buffer
      final input = [
        List.generate(inputSize, (y) {
          return List.generate(inputSize, (x) {
            final baseIndex = (y * inputSize + x) * 3;
            // Ensure we don't go out of bounds
            if (baseIndex + 2 >= inputBuffer.length) {
              throw Exception("Input buffer index out of bounds: $baseIndex");
            }
            return [
              inputBuffer[baseIndex],
              inputBuffer[baseIndex + 1],
              inputBuffer[baseIndex + 2],
            ];
          });
        })
      ];
      
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      if (outputShape.isEmpty) {
        throw Exception("Invalid output tensor shape: empty");
      }
      final outputSize = outputShape[outputShape.length - 1]; // Get last dimension size
      if (outputSize <= 0) {
        throw Exception("Invalid output size: $outputSize");
      }
      // Create output as nested list: [[output values]]
      final output = [List.filled(outputSize, 0.0)];
      
      _interpreter!.run(input, output);
      
      // Extract results from nested output
      final results = output[0] as List<double>;
      
      // Validate results
      if (results.isEmpty) {
        throw Exception("Model returned empty results");
      }
      
      // Store ALL predictions
      Map<String, double> predictions = {};
      int maxIndex = 0;
      double maxConfidence = results[0];
      
      for (int i = 0; i < results.length; i++) {
        String labelName = i < _labels.length ? _labels[i] : 'Class $i';
        predictions[labelName] = results[i] * 100;
        
        if (results[i] > maxConfidence) {
          maxConfidence = results[i];
          maxIndex = i;
        }
      }
      
      // Sort predictions by confidence (descending)
      var sortedPredictions = Map.fromEntries(
        predictions.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))
      );
      
      // Normalize predictions to ensure total is exactly 100%
      final total = sortedPredictions.values.fold<double>(0, (sum, value) => sum + value);
      if (total > 0) {
        final scale = 100.0 / total;
        sortedPredictions = Map<String, double>.fromEntries(
          sortedPredictions.entries.map(
            (entry) => MapEntry(entry.key, entry.value * scale),
          ),
        );
      }
      
      devtools.log("All predictions: $sortedPredictions");

      double detectedConfidence = maxConfidence * 100;
      String detectedLabel = maxIndex < _labels.length 
          ? _labels[maxIndex].replaceAll(RegExp(r'^\d+\s*'), '').trim()
          : 'Class $maxIndex';
      
      if (detectedConfidence < 30) {
        setState(() {
          confidence = detectedConfidence;
          label = 'LOW CONFIDENCE';
          isUnknown = true;
          isLoading = false;
          allPredictions = sortedPredictions;
        });
        // Add to history in background (non-blocking) so buttons can work immediately
        _addToHistory(image.path, 'Unknown - Low Confidence', detectedConfidence, true, sortedPredictions).catchError((e) {
          devtools.log("Error adding to history: $e");
        });
      } else {
        setState(() {
          confidence = detectedConfidence;
          label = detectedLabel.toUpperCase();
          isUnknown = false;
          isLoading = false;
          allPredictions = sortedPredictions;
        });
        // Add to history in background (non-blocking) so buttons can work immediately
        _addToHistory(image.path, detectedLabel, detectedConfidence, false, sortedPredictions).catchError((e) {
          devtools.log("Error adding to history: $e");
        });
      }
    } catch (e, stackTrace) {
      devtools.log("Error processing image: $e");
      devtools.log("Stack trace: $stackTrace");
      setState(() {
        isLoading = false;
        label = 'ERROR PROCESSING';
        isUnknown = true;
        confidence = 0.0;
        allPredictions = {};
      });
    } finally {
      // CRITICAL: Always reset processing flag to allow new scans
      // Reset flags immediately - this is the most important part
      _isProcessing = false;
      isLoading = false;
      
      // Force immediate UI update to ensure buttons are enabled
      if (mounted) {
        // Call setState immediately to rebuild UI
        setState(() {
          // Empty setState just forces rebuild - flags already reset above
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            ..._buildAmbientGlows(),
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Header
                  _buildHeader(),
                  const SizedBox(height: 20),
                  
                  // Main Scanner
                  _buildScannerContainer(),
                  const SizedBox(height: 20),
                  
                  // Action Buttons
                  _buildActionButtons(),
                  
                  // Prediction Chart (shows after scan)
                  if (allPredictions.isNotEmpty && !isLoading) ...[
                    const SizedBox(height: 24),
                    _buildSectionDivider(),
                    const SizedBox(height: 16),
                    _buildPredictionChart(),
                  ],
                  
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) {
            return Transform.rotate(
              angle: _rotationController.value * 2 * math.pi,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.neonCyan, AppColors.neonPurple],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.neonCyan.withOpacity(0.5),
                      blurRadius: 15,
                    ),
                  ],
                ),
                child: const Icon(Icons.hexagon_outlined, color: Colors.white, size: 24),
              ),
            );
          },
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [AppColors.neonCyan, AppColors.neonPurple],
                ).createShader(bounds),
                child: Text(
                  'KNIFE DETECTOR X',
                  style: GoogleFonts.orbitron(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
              ),
              Text(
                'AI-Powered Recognition',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScannerContainer() {
    return NeonGlowBox(
      glowColor: isUnknown && label.isNotEmpty 
          ? AppColors.danger 
          : AppColors.neonCyan,
      intensity: 0.3,
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        borderColor: isUnknown && label.isNotEmpty
            ? AppColors.danger.withOpacity(0.5)
            : AppColors.neonCyan.withOpacity(0.3),
        child: Column(
          children: [
            // Image Display
            Container(
              height: 250,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.neonCyan.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: filePath == null
                    ? _buildPlaceholder()
                    : _buildImageWithOverlay(),
              ),
            ),
            
            // Quick Results
            if (label.isNotEmpty && !isLoading) ...[
              const SizedBox(height: 16),
              _buildQuickResult(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Stack(
      children: [
        Center(
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.neonCyan.withOpacity(0.2),
                      width: 2,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [AppColors.neonCyan, AppColors.neonPurple],
                ).createShader(bounds),
                child: const Icon(
                  Icons.document_scanner_outlined,
                  size: 50,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'READY TO SCAN',
                style: GoogleFonts.orbitron(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.neonCyan,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImageWithOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(filePath!, fit: BoxFit.cover),
        if (isLoading) _buildLoadingOverlay(),
        if (isLoading)
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Positioned(
                top: _pulseController.value * 230,
                left: 0,
                right: 0,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        AppColors.neonCyan.withOpacity(0.8),
                        Colors.transparent,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.neonCyan.withOpacity(0.8),
                        blurRadius: 10,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: AppColors.background.withOpacity(0.85),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.neonCyan),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'ANALYZING...',
              style: GoogleFonts.orbitron(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.neonCyan,
                letterSpacing: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickResult() {
    final color = isUnknown ? AppColors.danger : AppColors.neonGreen;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.2), color.withOpacity(0.1)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(
            isUnknown ? Icons.warning_rounded : Icons.verified_rounded,
            color: color,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.orbitron(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'Top Match: ${confidence.toStringAsFixed(1)}%',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper function to filter and normalize predictions
  Map<String, double> _getFilteredPredictions() {
    // Filter predictions >= 0.1%
    final filtered = Map<String, double>.fromEntries(
      allPredictions.entries.where((entry) => entry.value >= 0.1)
    );
    
    if (filtered.isEmpty) return {};
    
    // Calculate total
    final total = filtered.values.fold<double>(0, (sum, value) => sum + value);
    
    // Normalize to ensure total is exactly 100%
    if (total > 0) {
      final scale = 100.0 / total;
      return Map<String, double>.fromEntries(
        filtered.entries.map((entry) => MapEntry(entry.key, entry.value * scale))
      );
    }
    
    return filtered;
  }

  // NEW: Prediction Chart showing ALL classes
  Widget _buildPredictionChart() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntry = entries.isNotEmpty ? entries.first : null;
    
    // Calculate other share from filtered predictions
    final totalFiltered = filteredPredictions.values.fold<double>(0, (sum, value) => sum + value);
    final otherShare = topEntry != null && entries.length > 1
        ? (totalFiltered - topEntry.value).clamp(0, 100).toStringAsFixed(1)
        : '0.0';
    return NeonGlowBox(
      glowColor: AppColors.neonPurple,
      intensity: 0.3,
      child: GlassContainer(
        borderColor: AppColors.neonPurple.withOpacity(0.3),
        child: Stack(
          children: [
            Positioned(
              right: -20,
              top: -30,
              child: _buildGlowCircle(AppColors.neonPink, size: 180),
            ),
            Positioned(
              left: -30,
              bottom: 70,
              child: _buildGlowCircle(AppColors.neonCyan, size: 160),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.neonPurple, AppColors.neonPink],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.pie_chart, size: 18, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'PREDICTION BREAKDOWN',
                      style: GoogleFonts.orbitron(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.neonPurple,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                
                if (topEntry != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricChip(
                          icon: Icons.auto_awesome,
                          label: 'TOP CLASS',
                          value: topEntry.key.toUpperCase(),
                          color: AppColors.neonCyan,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricChip(
                          icon: Icons.percent,
                          label: 'CONFIDENCE',
                          value: '${topEntry.value.toStringAsFixed(1)}%',
                          color: AppColors.neonPurple,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                
                Row(
                  children: [
                    Expanded(
                      child: _buildMetricChip(
                        icon: Icons.category_rounded,
                        label: 'CLASSES SEEN',
                        value: '${filteredPredictions.length}',
                        color: AppColors.neonOrange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildMetricChip(
                        icon: Icons.stacked_bar_chart_rounded,
                        label: 'OTHER SHARE',
                        value: entries.length > 1 ? '$otherShare%' : '—',
                        color: AppColors.neonPink,
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 18),
                
                // Horizontal Bar Chart for all predictions
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      colors: [
                        AppColors.surface.withOpacity(0.65),
                        AppColors.surface.withOpacity(0.35),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    border: Border.all(
                      color: AppColors.neonPurple.withOpacity(0.3),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                    child: _buildHorizontalBarChart(),
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Legend
                _buildLegend(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalBarChart() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Column(
      children: entries.asMap().entries.map((entry) {
        final label = entry.value.key;
        final value = entry.value.value.clamp(0, 100).toDouble();
        final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
        return _buildPredictionBarRow(label, value, color);
      }).toList(),
    );
  }

  Widget _buildPredictionBarRow(String label, double value, Color color) {
    String labelText = label;
    if (labelText.length > 20) {
      labelText = '${labelText.substring(0, 18)}…';
    }
    final widthFactor = value <= 0 ? 0.02 : (value / 100).clamp(0.05, 1.0).toDouble();
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  labelText.toUpperCase(),
                  style: GoogleFonts.orbitron(
                    fontSize: 11,
                    letterSpacing: 0.5,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${value.toStringAsFixed(1)}%',
                style: GoogleFonts.orbitron(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.card.withOpacity(0.5),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          color,
                          color.withOpacity(0.5),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: entries.asMap().entries.map((entry) {
        final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
        String labelText = entry.value.key;
        if (labelText.length > 10) {
          labelText = '${labelText.substring(0, 8)}..';
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(color: color.withOpacity(0.5), blurRadius: 4),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  labelText,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${entry.value.value.toStringAsFixed(1)}%',
                style: GoogleFonts.orbitron(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            onPressed: () async {
              // Always allow button press - let _processImage handle the check
              await _processImage(ImageSource.camera);
            },
            icon: Icons.camera_alt_rounded,
            label: 'CAMERA',
            color: AppColors.neonCyan,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionButton(
            onPressed: () async {
              // Always allow button press - let _processImage handle the check
              await _processImage(ImageSource.gallery);
            },
            icon: Icons.photo_library_rounded,
            label: 'GALLERY',
            color: AppColors.neonPurple,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return NeonGlowBox(
      glowColor: color,
      intensity: 0.3,
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color.withOpacity(0.3), color.withOpacity(0.1)],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Column(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: GoogleFonts.orbitron(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildAmbientGlows() {
    return [
      Positioned(
        top: -60,
        right: -30,
        child: _buildGlowCircle(AppColors.neonPurple, size: 220),
      ),
      Positioned(
        bottom: 90,
        left: -40,
        child: _buildGlowCircle(AppColors.neonCyan, size: 260),
      ),
    ];
  }

  Widget _buildGlowCircle(Color color, {double size = 200}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.35),
              color.withOpacity(0.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionDivider() {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            AppColors.neonCyan.withOpacity(0.35),
            AppColors.neonPurple.withOpacity(0.35),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildMetricChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [
            color.withOpacity(0.25),
            color.withOpacity(0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.2),
            ),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(
                  value,
                  style: GoogleFonts.orbitron(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== ANALYTICS PAGE ====================
class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> with WidgetsBindingObserver {
  int _lastHistoryVersion = 0;
  // Tooltip state for charts
  int? _touchedBarIndex;
  int? _touchedLineIndex;
  int? _touchedPieIndex;
  String? _tooltipText;
  Offset? _tooltipPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastHistoryVersion = historyVersion;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndUpdate();
    }
  }

  void _checkAndUpdate() {
    if (_lastHistoryVersion != historyVersion) {
      _lastHistoryVersion = historyVersion;
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check for updates when page becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndUpdate();
    });
  }

  Map<String, int> _getLabelCounts() {
    Map<String, int> counts = {};
    for (var item in detectionHistory) {
      String key = item.isUnknown ? 'Unknown' : item.topLabel;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> _getTrendDataset(Map<String, int> counts) {
    if (knownClassLabels.isEmpty) return counts;

    final Map<String, int> trend = {
      for (final label in knownClassLabels) label: counts[label] ?? 0,
    };

    if (counts.containsKey('Unknown')) {
      trend['Unknown'] = counts['Unknown']!;
    }

    return trend;
  }

  List<Map<String, dynamic>> _getDailyStats() {
    final now = DateTime.now();
    final Map<String, int> dailyCounts = {};
    
    // Initialize last 7 days with proper date matching (including year for accuracy)
    final List<DateTime> last7Days = [];
    for (int i = 6; i >= 0; i--) {
      final date = DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      last7Days.add(date);
      final key = '${date.year}-${date.month}-${date.day}';
      dailyCounts[key] = 0;
    }
    
    // Count scans for each day in the last 7 days (accurate date matching)
    for (var item in detectionHistory) {
      final itemDate = DateTime(item.timestamp.year, item.timestamp.month, item.timestamp.day);
      final key = '${itemDate.year}-${itemDate.month}-${itemDate.day}';
      
      if (dailyCounts.containsKey(key)) {
        dailyCounts[key] = dailyCounts[key]! + 1;
      }
    }
    
    // Convert to display format with day/month (preserving order)
    return last7Days.map((date) {
      final key = '${date.year}-${date.month}-${date.day}';
      return {
        'date': '${date.day}/${date.month}',
        'count': dailyCounts[key] ?? 0,
      };
    }).toList();
  }

  double _getAverageConfidence() {
    if (detectionHistory.isEmpty) return 0;
    double total = detectionHistory
        .where((e) => !e.isUnknown)
        .fold(0.0, (sum, item) => sum + item.topConfidence);
    int count = detectionHistory.where((e) => !e.isUnknown).length;
    return count > 0 ? total / count : 0;
  }

  @override
  Widget build(BuildContext context) {
    final labelCounts = _getLabelCounts();
    final trendDataset = _getTrendDataset(labelCounts);
    final dailyStats = _getDailyStats();
    final avgConfidence = _getAverageConfidence();
    final successRate = detectionHistory.isEmpty
        ? 0.0
        : (detectionHistory.where((e) => !e.isUnknown).length /
                detectionHistory.length) *
            100;
    final scannedClassCount = labelCounts.entries
        .where((e) => e.value > 0 && e.key != 'Unknown')
        .length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.neonCyan, AppColors.neonPurple],
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.neonCyan.withOpacity(0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Icon(Icons.analytics, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              'ANALYTICS',
              style: GoogleFonts.orbitron(
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          ..._buildAmbientGlows(),
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Stats Cards
                Row(
                  children: [
                    Expanded(child: _buildStatCard('Total Scans', '${detectionHistory.length}', Icons.document_scanner, AppColors.neonCyan)),
                    const SizedBox(width: 10),
                    Expanded(child: _buildStatCard('Success', '${successRate.toStringAsFixed(0)}%', Icons.check_circle, AppColors.neonGreen)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildStatCard('Avg Conf', '${avgConfidence.toStringAsFixed(0)}%', Icons.speed, AppColors.neonPurple)),
                    const SizedBox(width: 10),
                    Expanded(child: _buildStatCard('Classes', '$scannedClassCount', Icons.category, AppColors.neonOrange)),
                  ],
                ),
                const SizedBox(height: 20),

                // Weekly Activity
                _buildSectionTitle('WEEKLY ACTIVITY'),
                const SizedBox(height: 12),
                NeonGlowBox(
                  glowColor: AppColors.neonCyan,
                  intensity: 0.2,
                  child: GlassContainer(
                    child: SizedBox(
                      height: 180,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 8, left: 4, right: 8),
                        child: dailyStats.every((e) => e['count'] == 0)
                            ? _buildEmptyChart('No activity this week')
                            : _buildBarChart(dailyStats),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Detection Distribution
                _buildSectionTitle('DETECTION DISTRIBUTION'),
                const SizedBox(height: 12),
                NeonGlowBox(
                  glowColor: AppColors.neonPurple,
                  intensity: 0.2,
                  child: GlassContainer(
                    child: SizedBox(
                      height: 220,
                      child: labelCounts.isEmpty
                          ? _buildEmptyChart('No detections yet')
                          : _buildDistributionChart(labelCounts),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Class Scan Trend
                _buildSectionTitle('CLASS SCAN TREND'),
                const SizedBox(height: 12),
                NeonGlowBox(
                  glowColor: AppColors.neonPink,
                  intensity: 0.2,
                  child: GlassContainer(
                    child: SizedBox(
                      height: 220,
                      child: trendDataset.isEmpty
                          ? _buildEmptyChart('Scan some classes to see trends')
                          : _buildClassLineChart(trendDataset),
                    ),
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.neonCyan, AppColors.neonPurple],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: GoogleFonts.orbitron(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return NeonGlowBox(
      glowColor: color,
      intensity: 0.2,
      borderRadius: BorderRadius.circular(14),
      child: GlassContainer(
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.all(14),
        borderColor: color.withOpacity(0.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(
              value,
              style: GoogleFonts.orbitron(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              title,
              style: GoogleFonts.inter(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyChart(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_chart_outlined, size: 40, color: AppColors.textSecondary.withOpacity(0.5)),
          const SizedBox(height: 10),
          Text(message, style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  List<Widget> _buildAmbientGlows() {
    return [
      Positioned(
        top: -40,
        left: -30,
        child: _buildGlowCircle(AppColors.neonCyan, size: 200),
      ),
      Positioned(
        bottom: 120,
        right: -20,
        child: _buildGlowCircle(AppColors.neonPink, size: 240),
      ),
    ];
  }

  Widget _buildGlowCircle(Color color, {double size = 180}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.3),
              color.withOpacity(0.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBarChart(List<Map<String, dynamic>> data) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final maxCount = data.map((e) => e['count'] as int).reduce(math.max);
    // Add padding to prevent highest bar from being cropped (add 15% padding)
    var maxY = (maxCount * 1.15).ceil().toDouble();
    if (maxY < 1) maxY = 1.0; // Ensure at least 1.0
    
    return Stack(
      children: [
        BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxY,
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (value, meta) {
                    if (value.toInt() >= 0 && value.toInt() < data.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          data[value.toInt()]['date'],
                          style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 9),
                        ),
                      );
                    }
                    return const Text('');
                  },
                  reservedSize: 28,
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (value, meta) {
                    // Show count labels on left side
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        value.toInt().toString(),
                        style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  return null; // We'll handle tooltip manually
                },
              ),
              touchCallback: (FlTouchEvent event, barTouchResponse) {
                if (!event.isInterestedForInteractions ||
                    barTouchResponse == null ||
                    barTouchResponse.spot == null) {
                  setState(() {
                    _touchedBarIndex = null;
                    _tooltipText = null;
                    _tooltipPosition = null;
                  });
                  return;
                }
                
                final touchedIndex = barTouchResponse.spot!.touchedBarGroupIndex;
                if (touchedIndex >= 0 && touchedIndex < data.length) {
                  final item = data[touchedIndex];
                  if (!mounted) return;
                  final localPos = event.localPosition;
                  if (localPos == null) return;
                  
                  setState(() {
                    _touchedBarIndex = touchedIndex;
                    _tooltipText = '${item['date']}\n${item['count']} scans';
                    // Position tooltip below the bar or to the side if it's the highest
                    final barValue = item['count'] as int;
                    final isHighBar = barValue == maxCount;
                    // Smart positioning: below for high bars, above for others, with side offset if needed
                    final screenWidth = MediaQuery.of(context).size.width;
                    final xPos = localPos.dx;
                    final yPos = isHighBar 
                        ? localPos.dy + 70  // Below for high bars
                        : localPos.dy - 50; // Above for others
                    
                    // Adjust X position to keep tooltip on screen
                    double adjustedX = xPos;
                    if (xPos < 80) adjustedX = 80; // Keep away from left edge
                    if (xPos > screenWidth - 180) adjustedX = screenWidth - 180; // Keep away from right edge
                    
                    _tooltipPosition = Offset(adjustedX, yPos);
                  });
                }
              },
            ),
            barGroups: data.asMap().entries.map((entry) {
              final isTouched = entry.key == _touchedBarIndex;
              return BarChartGroupData(
                x: entry.key,
                barRods: [
                  BarChartRodData(
                    toY: entry.value['count'].toDouble(),
                    gradient: LinearGradient(
                      colors: isTouched
                          ? [AppColors.neonGreen, AppColors.neonCyan]
                          : [AppColors.neonCyan, AppColors.neonPurple],
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                    ),
                    width: isTouched ? 22 : 18,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
        // Tooltip overlay
        if (_touchedBarIndex != null && _tooltipText != null && _tooltipPosition != null)
          Positioned(
            left: _tooltipPosition!.dx - 60,
            top: _tooltipPosition!.dy,
            child: _buildChartTooltip(_tooltipText!),
          ),
      ],
    );
  }

  Widget _buildChartTooltip(String text) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface.withOpacity(0.98),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.neonCyan.withOpacity(0.7), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.neonCyan.withOpacity(0.4),
              blurRadius: 15,
              spreadRadius: 3,
            ),
          ],
        ),
        child: Text(
          text,
          style: GoogleFonts.orbitron(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildDistributionChart(Map<String, int> data) {
    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 35,
                  pieTouchData: PieTouchData(
                    enabled: true,
                    touchCallback: (FlTouchEvent event, pieTouchResponse) {
                      if (!event.isInterestedForInteractions ||
                          pieTouchResponse == null ||
                          pieTouchResponse.touchedSection == null) {
                        setState(() {
                          _touchedPieIndex = null;
                          _tooltipText = null;
                          _tooltipPosition = null;
                        });
                        return;
                      }
                      
                      final touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
                      if (touchedIndex >= 0 && touchedIndex < data.length) {
                        if (!mounted) return;
                        final localPos = event.localPosition;
                        if (localPos == null) return;
                        
                        final entry = data.entries.toList()[touchedIndex];
                        final screenWidth = MediaQuery.of(context).size.width;
                        final xPos = localPos.dx;
                        final yPos = localPos.dy - 50;
                        
                        // Adjust X position to keep tooltip on screen
                        double adjustedX = xPos;
                        if (xPos < 80) adjustedX = 80;
                        if (xPos > screenWidth - 180) adjustedX = screenWidth - 180;
                        
                        setState(() {
                          _touchedPieIndex = touchedIndex;
                          _tooltipText = '${entry.key}\n${entry.value} detections';
                          _tooltipPosition = Offset(adjustedX, yPos);
                        });
                      }
                    },
                  ),
                  sections: data.entries.toList().asMap().entries.map((entry) {
                    final isTouched = entry.key == _touchedPieIndex;
                    final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
                    return PieChartSectionData(
                      value: entry.value.value.toDouble(),
                      title: '${entry.value.value}',
                      color: color,
                      radius: isTouched ? 55 : 50,
                      titleStyle: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                    );
                  }).toList(),
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: data.entries.toList().asMap().entries.map((entry) {
                  final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            entry.value.key,
                            style: GoogleFonts.inter(fontSize: 10, color: AppColors.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        // Tooltip overlay for pie chart
        if (_touchedPieIndex != null && _tooltipText != null && _tooltipPosition != null)
          Positioned(
            left: _tooltipPosition!.dx - 60,
            top: _tooltipPosition!.dy,
            child: _buildChartTooltip(_tooltipText!),
          ),
      ],
    );
  }

  Widget _buildClassLineChart(Map<String, int> data) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final entries = data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final maxY = entries.map((e) => e.value.toDouble()).fold<double>(0, math.max) + 1;
    final maxX = entries.length > 1 ? entries.length - 1 : 1;
    // Add padding to prevent highest point from being cropped
    final paddedMaxY = (maxY * 1.15).ceil().toDouble();

    return Stack(
      children: [
        LineChart(
          LineChartData(
            minX: 0,
            maxX: maxX.toDouble(),
            minY: 0,
            maxY: paddedMaxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.white.withOpacity(0.05),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: const Border(
            top: BorderSide(color: Colors.transparent),
            right: BorderSide(color: Colors.transparent),
            left: BorderSide(color: Colors.white24),
            bottom: BorderSide(color: Colors.white24),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  value.toInt().toString(),
                  style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 9),
                ),
              ),
              reservedSize: 32,
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index >= 0 && index < entries.length) {
                  var label = entries[index].key;
                  if (label.length > 8) {
                    label = '${label.substring(0, 6)}..';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Transform.rotate(
                      angle: -0.35,
                      child: Text(
                        label,
                        style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 9),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (items) => [], // We'll handle tooltip manually
          ),
          touchCallback: (FlTouchEvent event, lineTouchResponse) {
            if (!event.isInterestedForInteractions ||
                lineTouchResponse == null ||
                lineTouchResponse.lineBarSpots == null ||
                lineTouchResponse.lineBarSpots!.isEmpty) {
              setState(() {
                _touchedLineIndex = null;
                _tooltipText = null;
                _tooltipPosition = null;
              });
              return;
            }
            
            final spot = lineTouchResponse.lineBarSpots![0];
            final index = spot.x.toInt();
            if (index >= 0 && index < entries.length) {
              final entry = entries[index];
              if (!mounted) return;
              final localPos = event.localPosition;
              if (localPos == null) return;
              
              setState(() {
                _touchedLineIndex = index;
                _tooltipText = '${entry.key}\n${entry.value} scans';
                // Position tooltip below the point or to the side if it's high
                final pointValue = entry.value.toDouble();
                final isHighPoint = pointValue >= maxY - 2;
                final screenWidth = MediaQuery.of(context).size.width;
                final xPos = localPos.dx;
                final yPos = isHighPoint 
                    ? localPos.dy + 70  // Below for high points
                    : localPos.dy - 50; // Above for others
                
                // Adjust X position to keep tooltip on screen
                double adjustedX = xPos;
                if (xPos < 80) adjustedX = 80;
                if (xPos > screenWidth - 180) adjustedX = screenWidth - 180;
                
                _tooltipPosition = Offset(adjustedX, yPos);
              });
            }
          },
        ),
        lineBarsData: [
          LineChartBarData(
            spots: entries.asMap().entries
                .map((entry) => FlSpot(entry.key.toDouble(), entry.value.value.toDouble()))
                .toList(),
            isCurved: true,
            gradient: const LinearGradient(
              colors: [AppColors.neonPink, AppColors.neonPurple],
            ),
            barWidth: 4,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) {
                final isTouched = index == _touchedLineIndex;
                return FlDotCirclePainter(
                  radius: isTouched ? 7 : 5,
                  color: isTouched ? AppColors.neonGreen : Colors.white,
                  strokeColor: isTouched ? AppColors.neonCyan : AppColors.neonPink,
                  strokeWidth: isTouched ? 3 : 2,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  AppColors.neonPink.withOpacity(0.2),
                  AppColors.neonPurple.withOpacity(0.05),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            shadow: const Shadow(
              color: Colors.black54,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ),
        ],
      ),
      ),
      // Tooltip overlay for line chart
      if (_touchedLineIndex != null && _tooltipText != null && _tooltipPosition != null)
        Positioned(
          left: _tooltipPosition!.dx - 60,
          top: _tooltipPosition!.dy,
          child: _buildChartTooltip(_tooltipText!),
        ),
    ],
    );
  }
}

// ==================== LOGS PAGE ====================
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> with WidgetsBindingObserver {
  int _lastHistoryVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastHistoryVersion = historyVersion;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndUpdate();
    }
  }

  void _checkAndUpdate() {
    if (_lastHistoryVersion != historyVersion) {
      _lastHistoryVersion = historyVersion;
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check for updates when page becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndUpdate();
      // Refresh data in background (non-blocking)
      Future.delayed(const Duration(milliseconds: 100), () {
        loadHistoryFromFirestore();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.neonCyan, AppColors.neonPurple],
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: AppColors.neonCyan.withOpacity(0.5), blurRadius: 10),
                ],
              ),
              child: const Icon(Icons.list_alt_rounded, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              'SCAN LOGS',
              style: GoogleFonts.orbitron(fontWeight: FontWeight.w900, letterSpacing: 2),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (detectionHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.danger),
              onPressed: _showClearDialog,
            ),
        ],
      ),
      body: detectionHistory.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              key: ValueKey('logs_$historyVersion'),
              padding: const EdgeInsets.all(16),
              itemCount: detectionHistory.length,
              cacheExtent: 500, // Cache more items for smoother scrolling
              itemBuilder: (context, index) {
                if (index >= detectionHistory.length) {
                  return const SizedBox.shrink();
                }
                return _buildLogItem(detectionHistory[index], index);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppColors.neonCyan, AppColors.neonPurple],
            ).createShader(bounds),
            child: const Icon(Icons.inbox_rounded, size: 80, color: Colors.white),
          ),
          const SizedBox(height: 20),
          Text(
            'NO LOGS',
            style: GoogleFonts.orbitron(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2),
          ),
          const SizedBox(height: 8),
          Text(
            'Your scan history will appear here',
            style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(DetectionItem item, int index) {
    final color = item.isUnknown ? AppColors.danger : AppColors.neonCyan;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _showDetailDialog(item),
              child: NeonGlowBox(
                glowColor: color,
                intensity: 0.15,
                child: GlassContainer(
                  padding: EdgeInsets.zero,
                  borderColor: color.withOpacity(0.3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Thumbnail
                      ClipRRect(
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
                        child: Image.file(
                          File(item.imagePath),
                          height: 90,
                          width: 90,
                          fit: BoxFit.cover,
                          cacheWidth: 90,
                          cacheHeight: 90,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              height: 90,
                              width: 90,
                              color: AppColors.surface,
                              child: const Icon(Icons.broken_image, color: AppColors.textSecondary),
                            );
                          },
                        ),
                      ),
                      // Info
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: color.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: color.withOpacity(0.5)),
                                      ),
                                      child: Text(
                                        item.isUnknown ? 'UNKNOWN' : 'DETECTED',
                                        style: GoogleFonts.orbitron(
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold,
                                          color: color,
                                          letterSpacing: 1,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _formatDateTime(item.timestamp),
                                      style: GoogleFonts.inter(fontSize: 10, color: AppColors.textSecondary),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                item.topLabel.toUpperCase(),
                                style: GoogleFonts.orbitron(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.speed, size: 12, color: color),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      '${item.topConfidence.toStringAsFixed(1)}%',
                                      style: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const Spacer(),
                                  Flexible(
                                    child: Text(
                                      'Tap to view →',
                                      style: GoogleFonts.inter(fontSize: 9, color: AppColors.textSecondary),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Delete Button
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _showDeleteDialog(item),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.danger.withOpacity(0.5)),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.danger,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDetailDialog(DetectionItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.neonCyan, AppColors.neonPurple],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.pie_chart, size: 20, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PREDICTION DETAILS',
                          style: GoogleFonts.orbitron(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.neonCyan,
                            letterSpacing: 1,
                          ),
                        ),
                        Text(
                          item.topLabel,
                          style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Image
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(item.imagePath),
                        height: 150,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        cacheWidth: 800,
                        cacheHeight: 600,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 150,
                            color: AppColors.card,
                            child: const Icon(Icons.broken_image, size: 50, color: AppColors.textSecondary),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Bar Chart
                    _buildDetailBarChart(item.allPredictions),
                    const SizedBox(height: 20),
                    // Pie Chart
                    SizedBox(
                      height: 200,
                      child: _buildDetailPieChart(item.allPredictions),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper function to filter and normalize predictions (for detail views)
  Map<String, double> _filterAndNormalizePredictions(Map<String, double> predictions) {
    // Filter predictions >= 0.1%
    final filtered = Map<String, double>.fromEntries(
      predictions.entries.where((entry) => entry.value >= 0.1)
    );
    
    if (filtered.isEmpty) return {};
    
    // Calculate total
    final total = filtered.values.fold<double>(0, (sum, value) => sum + value);
    
    // Normalize to ensure total is exactly 100%
    if (total > 0) {
      final scale = 100.0 / total;
      return Map<String, double>.fromEntries(
        filtered.entries.map((entry) => MapEntry(entry.key, entry.value * scale))
      );
    }
    
    return filtered;
  }

  Widget _buildDetailBarChart(Map<String, double> predictions) {
    final filteredPredictions = _filterAndNormalizePredictions(predictions);
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.neonPurple.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ALL CLASSES (≥0.1%)',
            style: GoogleFonts.orbitron(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppColors.neonPurple,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 16),
          ...entries.asMap().entries.map((entry) {
            final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
            final value = entry.value.value.clamp(0, 100).toDouble();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          entry.value.key,
                          style: GoogleFonts.inter(fontSize: 11, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${value.toStringAsFixed(1)}%',
                        style: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (value / 100).clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [color, color.withOpacity(0.6)]),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDetailPieChart(Map<String, double> predictions) {
    final filteredPredictions = _filterAndNormalizePredictions(predictions);
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 25,
              sections: entries.asMap().entries.map((entry) {
                final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
                final isTop = entry.key == 0;
                final value = entry.value.value.clamp(0, 100).toDouble();
                return PieChartSectionData(
                  value: value,
                  title: isTop ? '${value.toStringAsFixed(0)}%' : '',
                  color: color,
                  radius: isTop ? 50 : 40,
                  titleStyle: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                );
              }).toList(),
            ),
          ),
        ),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: entries.asMap().entries.map((entry) {
              final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        entry.value.key,
                        style: GoogleFonts.inter(fontSize: 9, color: AppColors.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  void _showDeleteDialog(DetectionItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_rounded, color: AppColors.danger),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'DELETE SCAN',
                style: GoogleFonts.orbitron(fontWeight: FontWeight.bold, color: AppColors.danger, letterSpacing: 1, fontSize: 14),
              ),
            ),
          ],
        ),
        content: Text(
          'Delete this scan log permanently?',
          style: GoogleFonts.inter(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: GoogleFonts.orbitron(color: AppColors.textSecondary, letterSpacing: 1)),
          ),
          TextButton(
            onPressed: () async {
              // Close confirmation dialog first
              Navigator.pop(context);
              
              // Update UI immediately (optimistic update) - NO LOADING DIALOG
              final itemIndex = detectionHistory.indexOf(item);
              if (itemIndex != -1) {
                detectionHistory.removeAt(itemIndex);
              }
              historyVersion++;
              onHistoryChanged?.call();
              if (mounted) {
                setState(() {});
              }
              
              // Show success immediately - deletion happens in background
              if (mounted) {
                showDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (successContext) => AlertDialog(
                    backgroundColor: AppColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: AppColors.neonGreen.withOpacity(0.5)),
                    ),
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle, color: AppColors.neonGreen),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            'DELETED SUCCESSFULLY',
                            style: GoogleFonts.orbitron(
                              fontWeight: FontWeight.bold,
                              color: AppColors.neonGreen,
                              letterSpacing: 1,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    content: Text(
                      'Scan has been deleted successfully.',
                      style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(successContext),
                        child: Text(
                          'OK',
                          style: GoogleFonts.orbitron(
                            color: AppColors.neonGreen,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              
              // Perform deletion in background (non-blocking)
              deleteScanFromFirestore(item).then((success) {
                // Only reload if deletion failed (to restore the item)
                if (!success && mounted) {
                  // Reload to restore the item that failed to delete
                  loadHistoryFromFirestore().then((_) {
                    if (mounted) {
                      setState(() {});
                      // Show error if deletion failed
                      showDialog(
                        context: context,
                        barrierDismissible: true,
                        builder: (errorContext) => AlertDialog(
                          backgroundColor: AppColors.card,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
                          ),
                          title: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline, color: AppColors.danger),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  'DELETE FAILED',
                                  style: GoogleFonts.orbitron(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.danger,
                                    letterSpacing: 1,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          content: Text(
                            'Failed to delete scan from server. Item restored.',
                            style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(errorContext),
                              child: Text(
                                'OK',
                                style: GoogleFonts.orbitron(
                                  color: AppColors.danger,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                  }).catchError((e) {
                    devtools.log("Error reloading history after failed deletion: $e");
                  });
                }
              }).catchError((e) {
                devtools.log("Error deleting from Firestore: $e");
              });
            },
            child: Text(
              'DELETE',
              style: GoogleFonts.orbitron(
                color: AppColors.danger,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_rounded, color: AppColors.danger),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'CLEAR LOGS',
                style: GoogleFonts.orbitron(fontWeight: FontWeight.bold, color: AppColors.danger, letterSpacing: 1, fontSize: 14),
              ),
            ),
          ],
        ),
        content: Text(
          'Delete all scan logs permanently?',
          style: GoogleFonts.inter(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: GoogleFonts.orbitron(color: AppColors.textSecondary, letterSpacing: 1)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // Close confirmation dialog first
              
              // Show loading indicator
              if (!context.mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => Center(
                  child: GlassContainer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.neonCyan),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Deleting all...',
                          style: GoogleFonts.orbitron(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              
              // Update UI immediately (optimistic update)
              detectionHistory.clear();
              historyVersion++;
              onHistoryChanged?.call();
              if (mounted) {
                setState(() {});
              }
              
              // Delete all from Firestore in background
              // Firestore batch operations have a limit of 500 documents
              bool success = true;
              try {
                final firestore = FirebaseFirestore.instance;
                final querySnapshot = await firestore.collection('scans').get();
                
                if (querySnapshot.docs.isEmpty) {
                  devtools.log("No scans to delete");
                } else {
                  // Process in batches of 500 (Firestore limit)
                  const int batchLimit = 500;
                  final docs = querySnapshot.docs;
                  
                  for (int i = 0; i < docs.length; i += batchLimit) {
                    final batch = firestore.batch();
                    final endIndex = (i + batchLimit < docs.length) ? i + batchLimit : docs.length;
                    
                    for (int j = i; j < endIndex; j++) {
                      batch.delete(docs[j].reference);
                    }
                    
                    await batch.commit();
                    devtools.log("Deleted batch ${(i ~/ batchLimit) + 1} (${endIndex - i} documents)");
                  }
                  
                  devtools.log("All ${docs.length} scans deleted from Firestore");
                }
              } catch (e) {
                devtools.log("Error deleting all from Firestore: $e");
                success = false;
              }
              
              // Only reload if deletion failed (to restore the items)
              if (!success) {
                loadHistoryFromFirestore().then((_) {
                  if (mounted) {
                    setState(() {});
                  }
                }).catchError((e) {
                  devtools.log("Error reloading history after failed deletion: $e");
                });
              }
              
              // Close loading dialog
              if (context.mounted) {
                Navigator.pop(context);
                
                // Always show notification
                await Future.delayed(const Duration(milliseconds: 100));
                
                if (!context.mounted) return;
                
                // Show success alert
                showDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (context) => AlertDialog(
                    backgroundColor: AppColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: AppColors.neonGreen.withOpacity(0.5)),
                    ),
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle, color: AppColors.neonGreen),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            'DELETED SUCCESSFULLY',
                            style: GoogleFonts.orbitron(
                              fontWeight: FontWeight.bold,
                              color: AppColors.neonGreen,
                              letterSpacing: 1,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    content: Text(
                      success 
                        ? 'All scans have been deleted successfully.'
                        : 'Scans cleared locally. Some may still exist in cloud.',
                      style: GoogleFonts.inter(color: AppColors.textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          'OK',
                          style: GoogleFonts.orbitron(
                            color: AppColors.neonGreen,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
            },
            child: Text('DELETE', style: GoogleFonts.orbitron(color: AppColors.danger, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays == 1) return 'Yesterday';
    return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }
}
