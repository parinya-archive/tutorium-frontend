import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tutorium_frontend/pages/home/teacher/register/payment_screen.dart';
import 'package:tutorium_frontend/pages/profile/all_classes_page.dart';
import 'package:tutorium_frontend/pages/widgets/cached_network_image.dart';
import 'package:tutorium_frontend/pages/widgets/history_class.dart';
import 'package:tutorium_frontend/service/api_client.dart' show ApiException;
import 'package:tutorium_frontend/service/classes.dart' as class_api;
import 'package:tutorium_frontend/service/class_categories.dart'
    as category_api;
import 'package:tutorium_frontend/service/learners.dart' as learner_api;
import 'package:tutorium_frontend/service/rating_service.dart';
import 'package:tutorium_frontend/service/teachers.dart' as teacher_api;
import 'package:tutorium_frontend/service/users.dart' as user_api;
import 'package:tutorium_frontend/util/cache_user.dart';
import 'package:tutorium_frontend/util/local_storage.dart';
import 'package:tutorium_frontend/util/class_enrollment_pipeline.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  user_api.User? user;
  List<class_api.ClassInfo> myClasses = [];
  bool isLoading = true;
  bool isClassesLoading = false;
  bool isTeacherRatingLoading = false;
  bool isUploadingImage = false;
  bool isEditingDescription = false;
  final TextEditingController _descriptionController = TextEditingController();
  String? userError;
  String? classesError;
  String? teacherRatingError;
  double? teacherRating;
  final RatingService _ratingService = RatingService();
  List<category_api.ClassCategory> _allCategories =
      <category_api.ClassCategory>[];
  List<int> _selectedCategoryIds = <int>[];
  bool _isInterestLoading = false;
  bool _isSavingInterests = false;
  String? _interestError;

  @override
  void initState() {
    super.initState();
    fetchUser();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> fetchUser({bool forceRefresh = false}) async {
    if (mounted) {
      setState(() {
        isLoading = true;
        userError = null;
      });
    } else {
      isLoading = true;
      userError = null;
    }

    try {
      final userId = await LocalStorage.getUserId();
      if (userId == null) {
        throw Exception('User ID not found in local storage');
      }

      final fetchedUser = await UserCache().getUser(
        userId,
        forceRefresh: forceRefresh,
      );

      if (!mounted) return;

      setState(() {
        user = fetchedUser;
        if (fetchedUser.teacher?.description != null) {
          _descriptionController.text = fetchedUser.teacher!.description!;
        }
      });

      if (fetchedUser.learner != null) {
        try {
          await LocalStorage.saveLearnerId(fetchedUser.learner!.id);
          debugPrint(
            '🧠 Profile: cached learnerId=${fetchedUser.learner!.id} locally',
          );
        } catch (e) {
          debugPrint('⚠️ Profile: failed to cache learnerId - $e');
        }
      }

      debugPrint(
        "DEBUG ProfilePage: user loaded - ${fetchedUser.firstName} ${fetchedUser.lastName}",
      );
      debugPrint(
        "DEBUG ProfilePage: user id=${fetchedUser.id}, balance=${fetchedUser.balance}",
      );

      // ===== Save user profile to LocalStorage for other pages to use =====
      debugPrint('💾 Saving user profile to LocalStorage cache...');
      try {
        // Generate email from user data if not available
        final userEmail = fetchedUser.studentId != null
            ? '${fetchedUser.studentId}@student.ku.th'
            : 'user${fetchedUser.id}@ku.th';

        final profileData = {
          'user_id': fetchedUser.id,
          'first_name': fetchedUser.firstName ?? '',
          'last_name': fetchedUser.lastName ?? '',
          'email': userEmail,
          'balance': fetchedUser.balance,
          'profile_picture': fetchedUser.profilePicture,
          'is_teacher': fetchedUser.teacher != null,
          'student_id': fetchedUser.studentId,
        };

        await LocalStorage.saveUserProfile(profileData);
        debugPrint('✅ User profile saved to cache');
        debugPrint('   Name: ${fetchedUser.firstName} ${fetchedUser.lastName}');
        debugPrint('   Email: $userEmail');

        // Also save to SharedPreferences for backward compatibility
        final prefs = await SharedPreferences.getInstance();
        final fullName =
            '${fetchedUser.firstName ?? ''} ${fetchedUser.lastName ?? ''}'
                .trim();
        if (fullName.isNotEmpty) {
          await prefs.setString('userName', fullName);
        }
        await prefs.setString('userEmail', userEmail);
        debugPrint(
          '✅ Also saved to SharedPreferences (backward compatibility)',
        );
      } catch (e) {
        debugPrint('⚠️ Failed to save user profile to cache: $e');
      }

      await _hydrateLearnerInterests(fetchedUser, forceRefresh: forceRefresh);
      await fetchTeacherRating(fetchedUser);
      await fetchClasses(fetchedUser);
    } on ApiException catch (e) {
      debugPrint("Error fetching user (API): $e");
      if (mounted) {
        setState(() {
          userError = 'ไม่สามารถโหลดข้อมูลผู้ใช้ได้ (${e.statusCode})';
          user = null;
        });
      }
    } catch (e) {
      debugPrint("Error fetching user: $e");
      if (mounted) {
        setState(() {
          userError = 'เกิดข้อผิดพลาดในการโหลดข้อมูลผู้ใช้';
          user = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      } else {
        isLoading = false;
      }
    }
  }

  Future<void> fetchTeacherRating(user_api.User currentUser) async {
    if (currentUser.teacher == null) {
      if (mounted) {
        setState(() {
          teacherRating = null;
          teacherRatingError = null;
        });
      } else {
        teacherRating = null;
        teacherRatingError = null;
      }
      return;
    }

    final teacherId = currentUser.teacher!.id;
    debugPrint('🌟 Profile: fetching teacher rating for teacherId=$teacherId');

    if (mounted) {
      setState(() {
        isTeacherRatingLoading = true;
        teacherRatingError = null;
      });
    } else {
      isTeacherRatingLoading = true;
      teacherRatingError = null;
    }

    try {
      final rating = await _ratingService.getTeacherRating(teacherId);
      if (!mounted) return;
      setState(() {
        teacherRating = rating;
      });
    } catch (e) {
      debugPrint('❌ Profile: failed to load teacher rating - $e');
      if (mounted) {
        setState(() {
          teacherRating = null;
          teacherRatingError = 'ไม่สามารถโหลดคะแนนผู้สอนได้';
        });
      } else {
        teacherRating = null;
        teacherRatingError = 'ไม่สามารถโหลดคะแนนผู้สอนได้';
      }
    } finally {
      if (mounted) {
        setState(() {
          isTeacherRatingLoading = false;
        });
      } else {
        isTeacherRatingLoading = false;
      }
    }
  }

  Future<void> fetchClasses(user_api.User currentUser) async {
    if (currentUser.teacher == null) {
      if (mounted) {
        setState(() {
          myClasses = [];
          classesError = null;
        });
      } else {
        myClasses = [];
        classesError = null;
      }
      return;
    }

    if (mounted) {
      setState(() {
        isClassesLoading = true;
        classesError = null;
      });
    } else {
      isClassesLoading = true;
      classesError = null;
    }

    try {
      final teacherId = currentUser.teacher!.id;
      final teacherFullName =
          '${currentUser.firstName ?? ''} ${currentUser.lastName ?? ''}'
              .trim()
              .replaceAll(RegExp(r'\s{2,}'), ' ');

      debugPrint(
        '📚 Profile: loading classes for teacherId=$teacherId '
        '(userId=${currentUser.id})',
      );
      var classes = await class_api.ClassInfo.fetchByTeacher(
        teacherId,
        teacherName: teacherFullName.isEmpty ? null : teacherFullName,
      );
      debugPrint('📚 Profile: received ${classes.length} classes from backend');

      final enrollmentCounts =
          await ClassEnrollmentPipeline.aggregateActiveEnrollments(classes);

      classes = classes
          .map(
            (cls) => cls.copyWith(
              enrolledLearners:
                  enrollmentCounts[cls.id] ?? cls.enrolledLearners ?? 0,
            ),
          )
          .toList();

      classes.sort((a, b) => b.rating.compareTo(a.rating));

      if (!mounted) return;

      setState(() {
        myClasses = classes;
      });
    } on ApiException catch (e) {
      debugPrint('Error fetching classes (API): $e');
      if (mounted) {
        setState(() {
          classesError = 'ไม่สามารถโหลดคลาสได้ (${e.statusCode})';
          myClasses = [];
        });
      } else {
        classesError = 'ไม่สามารถโหลดคลาสได้ (${e.statusCode})';
        myClasses = [];
      }
    } catch (e) {
      debugPrint('Error fetching classes: $e');
      if (mounted) {
        setState(() {
          classesError = 'เกิดข้อผิดพลาดในการโหลดคลาส';
          myClasses = [];
        });
      } else {
        classesError = 'เกิดข้อผิดพลาดในการโหลดคลาส';
        myClasses = [];
      }
    } finally {
      if (mounted) {
        setState(() {
          isClassesLoading = false;
        });
      } else {
        isClassesLoading = false;
      }
    }
  }

  Future<void> _hydrateLearnerInterests(
    user_api.User fetchedUser, {
    bool forceRefresh = false,
  }) async {
    final learner = fetchedUser.learner;
    if (learner == null) {
      if (mounted) {
        setState(() {
          _selectedCategoryIds = <int>[];
          _interestError = null;
          _isInterestLoading = false;
        });
      } else {
        _selectedCategoryIds = <int>[];
        _interestError = null;
        _isInterestLoading = false;
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isInterestLoading = true;
        if (forceRefresh) {
          _interestError = null;
        }
      });
    } else {
      _isInterestLoading = true;
      if (forceRefresh) {
        _interestError = null;
      }
    }

    try {
      final categories = await _loadCategories(forceRefresh: forceRefresh);
      final interestState =
          await learner_api.LearnerInterestService.fetchInterests(learner.id);
      final selection = _mapCategoryNamesToIds(
        interestState.categories,
        categories,
      );
      final updatedLearner = learner.copyWith(
        interestedCategories: interestState.categories,
      );
      final updatedUser = fetchedUser.copyWith(learner: updatedLearner);

      if (mounted) {
        setState(() {
          user = updatedUser;
          _allCategories = categories;
          _selectedCategoryIds = selection;
          _interestError = null;
        });
      } else {
        user = updatedUser;
        _allCategories = categories;
        _selectedCategoryIds = selection;
        _interestError = null;
      }

      UserCache().updateUser(updatedUser);
      debugPrint(
        '🎯 Profile: synced ${selection.length} learner interests (learnerId=${learner.id})',
      );
    } on ApiException catch (e) {
      final message = 'ไม่สามารถโหลดสิ่งที่ชอบได้ (${e.statusCode})';
      debugPrint('❌ Profile interests API error: $e');
      if (mounted) {
        setState(() {
          _interestError = message;
        });
      } else {
        _interestError = message;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Profile interests error: $e');
      debugPrint('$stackTrace');
      const message = 'เกิดข้อผิดพลาดในการโหลดสิ่งที่ชอบ';
      if (mounted) {
        setState(() {
          _interestError = message;
        });
      } else {
        _interestError = message;
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInterestLoading = false;
        });
      } else {
        _isInterestLoading = false;
      }
    }
  }

  Future<List<category_api.ClassCategory>> _loadCategories({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _allCategories.isNotEmpty) {
      return _allCategories;
    }
    final categories = await category_api.ClassCategory.fetchAll();
    final sorted = List<category_api.ClassCategory>.from(categories)
      ..sort(
        (a, b) => a.classCategory.toLowerCase().compareTo(
          b.classCategory.toLowerCase(),
        ),
      );
    return sorted;
  }

  List<int> _mapCategoryNamesToIds(
    List<String> names,
    List<category_api.ClassCategory> categories,
  ) {
    if (names.isEmpty) return <int>[];
    final lookup = <String, int>{
      for (final category in categories)
        category.classCategory.toLowerCase(): category.id,
    };
    final ids =
        names
            .map((name) => lookup[name.toLowerCase()])
            .whereType<int>()
            .toSet()
            .toList(growable: false)
          ..sort();
    return ids;
  }

  List<String> _mapCategoryIdsToNames(
    Iterable<int> ids,
    List<category_api.ClassCategory> categories,
  ) {
    if (ids.isEmpty) return const <String>[];
    final lookup = <int, String>{
      for (final category in categories) category.id: category.classCategory,
    };
    final names =
        ids
            .map((id) => lookup[id])
            .whereType<String>()
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  Widget _buildTeacherRatingRow() {
    if (user?.teacher == null) {
      return const SizedBox.shrink();
    }

    if (teacherRatingError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Teacher rating : ${teacherRatingError!}',
          style: TextStyle(
            fontSize: 14,
            color: Colors.red.shade400,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    if (isTeacherRatingLoading) {
      return Row(
        children: const [
          Text(
            "Teacher rating : ",
            style: TextStyle(fontSize: 16, color: Colors.black),
          ),
          SizedBox(width: 6),
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      );
    }

    final rating = teacherRating ?? 0;
    final hasRating = rating > 0;

    return Row(
      children: [
        const Text(
          "Teacher rating : ",
          style: TextStyle(fontSize: 16, color: Colors.black),
        ),
        Icon(Icons.star, color: Colors.amber.shade600, size: 18),
        const SizedBox(width: 4),
        Text(
          hasRating ? rating.toStringAsFixed(1) : 'ยังไม่มีคะแนน',
          style: const TextStyle(fontSize: 16, color: Colors.black),
        ),
      ],
    );
  }

  Widget _buildInterestsCard() {
    if (user?.learner == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final interests = user?.learner?.interestedCategories ?? const <String>[];
    final hasInterests = interests.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Material(
        elevation: 1.5,
        borderRadius: BorderRadius.circular(18),
        color: theme.cardColor,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.favorite,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'สิ่งที่ชอบ',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          hasInterests
                              ? 'ใช้เพื่อแนะนำคลาสที่ตรงใจคุณมากขึ้น'
                              : 'ยังไม่ได้เลือกสิ่งที่ชอบ ลองเพิ่มเพื่อรับคำแนะนำเฉพาะคุณ',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: (_isInterestLoading || _isSavingInterests)
                        ? null
                        : _openInterestEditor,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('แก้ไข'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_isInterestLoading)
                const Center(
                  child: SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_interestError != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _interestError!,
                      style: TextStyle(
                        color: Colors.red.shade500,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () {
                        final currentUser = user;
                        if (currentUser != null) {
                          _hydrateLearnerInterests(
                            currentUser,
                            forceRefresh: true,
                          );
                        }
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('ลองอีกครั้ง'),
                    ),
                  ],
                )
              else if (hasInterests)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: interests
                      .map(
                        (name) => Chip(
                          label: Text(name),
                          backgroundColor: theme.colorScheme.primary
                              .withOpacity(0.08),
                          labelStyle: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                      .toList(growable: false),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline, color: Colors.amber[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'เลือกหมวดหมู่ที่คุณสนใจเพื่อให้ระบบแนะนำคลาสได้ตรงความต้องการมากขึ้น',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openInterestEditor() async {
    if (_isInterestLoading || _isSavingInterests || user?.learner == null) {
      return;
    }

    try {
      final categories = await _loadCategories();
      if (mounted) {
        setState(() {
          _allCategories = categories;
        });
      } else {
        _allCategories = categories;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Profile: failed to load categories $e');
      debugPrint('$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('โหลดหมวดหมู่ไม่สำเร็จ กรุณาลองใหม่')),
      );
      return;
    }

    if (!mounted) return;

    final sortedCategories =
        List<category_api.ClassCategory>.from(_allCategories)..sort(
          (a, b) => a.classCategory.toLowerCase().compareTo(
            b.classCategory.toLowerCase(),
          ),
        );
    final originalSelection = Set<int>.from(_selectedCategoryIds);
    final selection = Set<int>.from(_selectedCategoryIds);
    String keyword = '';
    bool localSaving = false;
    final controller = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final visibleCategories = sortedCategories
                .where((category) {
                  if (keyword.isEmpty) return true;
                  return category.classCategory.toLowerCase().contains(
                    keyword.toLowerCase(),
                  );
                })
                .toList(growable: false);

            return GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  child: Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 48,
                            height: 4,
                            margin: const EdgeInsets.only(top: 12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'เลือกสิ่งที่ชอบ',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${selection.length}/${sortedCategories.length}',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                hintText: 'ค้นหาหมวดหมู่...',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: keyword.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          setModalState(() {
                                            keyword = '';
                                            controller.clear();
                                          });
                                        },
                                      ),
                                filled: true,
                                fillColor: Colors.grey.shade200,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (value) {
                                setModalState(() {
                                  keyword = value.trim();
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (visibleCategories.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 36,
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.search_off,
                                    size: 48,
                                    color: Colors.grey.shade400,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'ไม่พบหมวดหมู่ที่ตรงกับ "${controller.text}"',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 14,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            )
                          else
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    MediaQuery.of(context).size.height * 0.45,
                              ),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: visibleCategories
                                      .map((category) {
                                        final isSelected = selection.contains(
                                          category.id,
                                        );
                                        return FilterChip(
                                          label: Text(category.classCategory),
                                          selected: isSelected,
                                          showCheckmark: true,
                                          selectedColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withOpacity(0.15),
                                          onSelected: (value) {
                                            setModalState(() {
                                              if (value) {
                                                selection.add(category.id);
                                              } else {
                                                selection.remove(category.id);
                                              }
                                            });
                                          },
                                        );
                                      })
                                      .toList(growable: false),
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                            child: Row(
                              children: [
                                TextButton(
                                  onPressed: selection.isEmpty
                                      ? null
                                      : () {
                                          setModalState(selection.clear);
                                        },
                                  child: const Text('ล้างทั้งหมด'),
                                ),
                                const Spacer(),
                                SizedBox(
                                  width: 160,
                                  child: ElevatedButton(
                                    onPressed: localSaving
                                        ? null
                                        : () async {
                                            await _persistLearnerInterests(
                                              sheetContext,
                                              Set<int>.from(selection),
                                              originalSelection,
                                              categories: sortedCategories,
                                              onSavingChanged: (value) {
                                                setModalState(
                                                  () => localSaving = value,
                                                );
                                              },
                                            );
                                          },
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 14,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: localSaving
                                        ? const SizedBox(
                                            height: 18,
                                            width: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text(
                                            'บันทึก',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    controller.dispose();
  }

  Future<void> _persistLearnerInterests(
    BuildContext sheetContext,
    Set<int> nextSelection,
    Set<int> previousSelection, {
    required List<category_api.ClassCategory> categories,
    required void Function(bool isSaving) onSavingChanged,
  }) async {
    if (_isSavingInterests) return;

    final additions = nextSelection
        .difference(previousSelection)
        .toList(growable: false);
    final removals = previousSelection
        .difference(nextSelection)
        .toList(growable: false);

    if (additions.isEmpty && removals.isEmpty) {
      Navigator.of(sheetContext).pop();
      return;
    }

    onSavingChanged(true);
    if (mounted) {
      setState(() {
        _isSavingInterests = true;
      });
    } else {
      _isSavingInterests = true;
    }

    var sheetClosed = false;

    try {
      final learnerId = user?.learner?.id;
      if (learnerId == null) {
        throw StateError('Learner ID is not available');
      }

      learner_api.LearnerInterestState? latestState;

      if (additions.isNotEmpty) {
        latestState = await learner_api.LearnerInterestService.addInterests(
          learnerId,
          additions,
        );
      }

      if (removals.isNotEmpty) {
        latestState = await learner_api.LearnerInterestService.removeInterests(
          learnerId,
          removals,
        );
      }

      final resolvedNames =
          latestState?.categories ??
          _mapCategoryIdsToNames(nextSelection, categories);
      final normalizedSelection = _mapCategoryNamesToIds(
        resolvedNames,
        categories,
      );

      if (mounted) {
        setState(() {
          _selectedCategoryIds = normalizedSelection;
          _isSavingInterests = false;
          _interestError = null;
          user = user?.copyWith(
            learner: user?.learner?.copyWith(
              interestedCategories: resolvedNames,
            ),
          );
        });
      } else {
        _selectedCategoryIds = normalizedSelection;
        _isSavingInterests = false;
        _interestError = null;
        user = user?.copyWith(
          learner: user?.learner?.copyWith(interestedCategories: resolvedNames),
        );
      }

      if (user != null) {
        UserCache().updateUser(user!);
      }

      if (mounted) {
        Navigator.of(sheetContext).pop();
        sheetClosed = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('อัปเดตสิ่งที่ชอบเรียบร้อยแล้ว')),
        );
      }
    } on ApiException catch (e) {
      debugPrint('❌ Profile: failed to update interests - $e');
      final message = e.statusCode == 400
          ? 'เลือกรายการไม่ถูกต้อง กรุณาลองใหม่'
          : 'ไม่สามารถบันทึกสิ่งที่ชอบได้ (${e.statusCode})';
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Profile: unexpected error while saving interests - $e');
      debugPrint('$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('เกิดข้อผิดพลาด กรุณาลองใหม่อีกครั้ง')),
        );
      }
    } finally {
      if (!sheetClosed) {
        onSavingChanged(false);
      }
      if (mounted) {
        setState(() {
          _isSavingInterests = false;
        });
      } else {
        _isSavingInterests = false;
      }
    }
  }

  Future<String?> pickImageAndConvertToBase64() async {
    final picker = ImagePicker();
    try {
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);

      if (pickedFile == null) {
        return null;
      }

      final fileName = pickedFile.name.toLowerCase();
      const allowedExtensions = {'jpg', 'jpeg', 'png', 'heic', 'heif'};
      final extension = fileName.split('.').last;

      if (!allowedExtensions.contains(extension)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'รองรับเฉพาะไฟล์ .jpg, .jpeg, .png, .heic และ .heif เท่านั้น',
              ),
            ),
          );
        }
        return null;
      }

      final bytes = await pickedFile.readAsBytes();
      final base64String = base64Encode(bytes);
      final mimeType = switch (extension) {
        'png' => 'image/png',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        _ => 'image/jpeg',
      };
      return 'data:$mimeType;base64,$base64String';
    } on PlatformException catch (e) {
      debugPrint('Image picker error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ไม่สามารถเปิดคลังรูปภาพได้')),
        );
      }
    } catch (e) {
      debugPrint('Unexpected image picker error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('เกิดข้อผิดพลาดในการเลือกรูป')),
        );
      }
    }
    return null;
  }

  Future<void> uploadProfilePicture(int userId, String base64Image) async {
    if (user == null) return;

    if (mounted) {
      setState(() {
        isUploadingImage = true;
      });
    } else {
      isUploadingImage = true;
    }

    try {
      final updatedUser = await user_api.User.update(
        userId,
        user_api.User(
          id: user!.id,
          studentId: user!.studentId,
          firstName: user!.firstName,
          lastName: user!.lastName,
          gender: user!.gender,
          phoneNumber: user!.phoneNumber,
          balance: user!.balance,
          banCount: user!.banCount,
          profilePicture: base64Image,
        ),
      );

      // Update cache with new user data
      UserCache().updateUser(updatedUser);

      if (mounted) {
        setState(() {
          user = updatedUser;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated')),
        );
        // Refresh user data to get the latest profile picture
        await fetchUser(forceRefresh: true);
      }
      debugPrint("Upload success");
    } catch (e) {
      debugPrint("Upload failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update profile picture')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isUploadingImage = false;
        });
      } else {
        isUploadingImage = false;
      }
    }
  }

  Future<void> _onProfileImageTap() async {
    if (isLoading || user == null || isUploadingImage) return;

    final base64Image = await pickImageAndConvertToBase64();
    if (base64Image != null) {
      await uploadProfilePicture(user!.id, base64Image);
    }
  }

  ImageProvider? _getImageProvider(String? value) {
    if (value == null || value.isEmpty) return null;

    if (value.startsWith("http")) {
      return NetworkImage(value);
    } else {
      try {
        final payload = value.startsWith('data:image')
            ? value.substring(value.indexOf(',') + 1)
            : value;
        return MemoryImage(base64Decode(payload));
      } catch (e) {
        debugPrint('Failed to decode profile image: $e');
        return null;
      }
    }
  }

  Future<void> _updateTeacherDescription() async {
    if (user?.teacher == null) return;

    final newDescription = _descriptionController.text.trim();

    if (newDescription.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Description cannot be empty')),
      );
      return;
    }

    try {
      debugPrint(
        "DEBUG: Updating teacher description for teacher ID ${user!.teacher!.id}",
      );

      final updatedTeacher = teacher_api.Teacher(
        id: user!.teacher!.id,
        userId: user!.teacher!.userId,
        email: user!.teacher!.email ?? '',
        description: newDescription,
        flagCount: user!.teacher!.flagCount ?? 0,
      );

      await teacher_api.Teacher.update(user!.teacher!.id, updatedTeacher);

      if (!mounted) return;

      setState(() {
        isEditingDescription = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Description updated successfully'),
          backgroundColor: Colors.green,
        ),
      );

      // Refresh user data
      await fetchUser(forceRefresh: true);

      debugPrint("DEBUG: Description updated successfully");
    } catch (e) {
      debugPrint("ERROR: Failed to update description: $e");

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update description: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _toggleEditDescription() {
    setState(() {
      if (isEditingDescription) {
        // Cancel editing - restore original description
        if (user?.teacher?.description != null) {
          _descriptionController.text = user!.teacher!.description!;
        }
        isEditingDescription = false;
      } else {
        // Start editing
        isEditingDescription = true;
      }
    });
  }

  Future<void> _handleLogout() async {
    // Show confirmation dialog
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(Icons.logout, color: Colors.red[700], size: 28),
              const SizedBox(width: 12),
              const Text(
                'ออกจากระบบ',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
              ),
            ],
          ),
          content: const Text(
            'คุณต้องการออกจากระบบใช่หรือไม่?',
            style: TextStyle(fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: Colors.grey[700]),
              child: const Text('ยกเลิก', style: TextStyle(fontSize: 16)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[700],
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'ออกจากระบบ',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    // If user confirmed logout
    if (shouldLogout == true) {
      try {
        // Clear cache
        UserCache().clear();

        // Clear local storage
        await LocalStorage.clear();

        if (!mounted) return;

        // Navigate to login page and remove all previous routes
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/login', (route) => false);

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ออกจากระบบสำเร็จ'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      } catch (e) {
        debugPrint('Error during logout: $e');
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: const Text("Your Profile"),
            ),
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_balance_wallet,
                    color: Colors.grey,
                    size: 25,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isLoading ? "..." : (user?.balance.toString() ?? "0.0"),
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () async {
                      if (isLoading || user == null) return;
                      final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PaymentScreen(userId: user!.id),
                        ),
                      );

                      // Refresh user data if payment was successful
                      if (result == true) {
                        await fetchUser(forceRefresh: true);
                      }
                    },
                    child: const Icon(
                      Icons.add_circle_rounded,
                      color: Colors.grey,
                      size: 25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        titleTextStyle: const TextStyle(
          color: Colors.black,
          fontSize: 36.0,
          fontWeight: FontWeight.normal,
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => fetchUser(forceRefresh: true),
              child: user == null
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 80),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            userError ?? 'ไม่พบข้อมูลผู้ใช้ โปรดลองรีเฟรช',
                            style: TextStyle(
                              color: userError != null
                                  ? Colors.red.shade400
                                  : Colors.black87,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Icon(Icons.refresh, size: 32, color: Colors.grey),
                        const SizedBox(height: 80),
                      ],
                    )
                  : SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Column(
                        children: [
                          const SizedBox(height: 40),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(width: 15),

                              GestureDetector(
                                onTap: _onProfileImageTap,
                                child: SizedBox(
                                  width: 100,
                                  height: 100,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // Use cached circular avatar
                                      user?.profilePicture != null &&
                                              user!
                                                  .profilePicture!
                                                  .isNotEmpty &&
                                              user!.profilePicture!.startsWith(
                                                'http',
                                              )
                                          ? CachedCircularAvatar(
                                              imageUrl: user!.profilePicture!,
                                              radius: 50,
                                              backgroundColor: Colors.grey[200],
                                            )
                                          : CircleAvatar(
                                              radius: 50,
                                              backgroundColor: Colors.grey[200],
                                              backgroundImage:
                                                  _getImageProvider(
                                                    user?.profilePicture,
                                                  ),
                                              child:
                                                  _getImageProvider(
                                                        user?.profilePicture,
                                                      ) ==
                                                      null
                                                  ? const Icon(
                                                      Icons
                                                          .account_circle_rounded,
                                                      color: Colors.black,
                                                      size: 100,
                                                    )
                                                  : null,
                                            ),
                                      if (isUploadingImage)
                                        Container(
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Color.fromRGBO(0, 0, 0, 0.4),
                                          ),
                                          child: const Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      Positioned(
                                        bottom: 6,
                                        right: 6,
                                        child: CircleAvatar(
                                          radius: 15,
                                          backgroundColor: Colors.black54,
                                          child: const Icon(
                                            Icons.camera_alt,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              const SizedBox(width: 20),

                              if (!isLoading)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          "${user?.firstName ?? ''} ${user?.lastName ?? ''}",
                                          style: const TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          user?.gender?.toLowerCase() == "male"
                                              ? Icons.male
                                              : user?.gender?.toLowerCase() ==
                                                    "female"
                                              ? Icons.female
                                              : Icons.account_circle_rounded,
                                          color:
                                              user?.gender?.toLowerCase() ==
                                                  "male"
                                              ? Colors.blue
                                              : user?.gender?.toLowerCase() ==
                                                    "female"
                                              ? Colors.red
                                              : Colors.black,
                                          size: 30,
                                        ),
                                      ],
                                    ),
                                    if (user?.teacher != null)
                                      Text(
                                        "Email : ${user!.teacher!.email}",
                                        style: const TextStyle(
                                          fontSize: 16,
                                          color: Colors.black,
                                        ),
                                      ),
                                    if (user?.learner != null &&
                                        user?.teacher != null)
                                      Text(
                                        "Learner & Teacher",
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.black,
                                        ),
                                      )
                                    else if (user?.learner != null &&
                                        user?.teacher == null)
                                      Text(
                                        "Learner",
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.black,
                                        ),
                                      )
                                    else if (user?.learner == null &&
                                        user?.teacher != null)
                                      Text(
                                        "Teacher",
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.black,
                                        ),
                                      ),
                                    if (user?.teacher != null)
                                      _buildTeacherRatingRow(),
                                  ],
                                )
                              else
                                const Text("Loading..."),
                            ],
                          ),
                          const SizedBox(height: 20),

                          _buildInterestsCard(),

                          const SizedBox(height: 10),

                          // Description Section Header with Edit Button
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Description",
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (user?.teacher != null)
                                  IconButton(
                                    onPressed: _toggleEditDescription,
                                    icon: Icon(
                                      isEditingDescription
                                          ? Icons.close
                                          : Icons.edit,
                                      color: isEditingDescription
                                          ? Colors.red
                                          : Colors.blue,
                                    ),
                                    tooltip: isEditingDescription
                                        ? 'Cancel'
                                        : 'Edit Description',
                                  ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Description Content
                          if (user?.teacher != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!isEditingDescription)
                                    // View Mode
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.grey[100],
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.grey[300]!,
                                        ),
                                      ),
                                      child: Text(
                                        user!
                                                    .teacher!
                                                    .description
                                                    ?.isNotEmpty ==
                                                true
                                            ? user!.teacher!.description!
                                            : "No description provided yet.",
                                        style: TextStyle(
                                          fontSize: 16,
                                          color:
                                              user!
                                                      .teacher!
                                                      .description
                                                      ?.isNotEmpty ==
                                                  true
                                              ? Colors.black87
                                              : Colors.grey,
                                          height: 1.5,
                                        ),
                                      ),
                                    )
                                  else
                                    // Edit Mode
                                    Column(
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            border: Border.all(
                                              color: Colors.blue,
                                              width: 2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.blue.withValues(
                                                  alpha: 0.1,
                                                ),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: TextField(
                                            controller: _descriptionController,
                                            maxLines: 6,
                                            maxLength: 500,
                                            decoration: const InputDecoration(
                                              hintText:
                                                  'Write a brief description about yourself as a teacher...',
                                              border: InputBorder.none,
                                              contentPadding: EdgeInsets.all(
                                                16,
                                              ),
                                              counterText: '',
                                            ),
                                            style: const TextStyle(
                                              fontSize: 16,
                                              height: 1.5,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Text(
                                              '${_descriptionController.text.length}/500',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color:
                                                    _descriptionController
                                                            .text
                                                            .length >
                                                        450
                                                    ? Colors.orange
                                                    : Colors.grey,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: _toggleEditDescription,
                                              icon: const Icon(Icons.cancel),
                                              label: const Text('Cancel'),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor:
                                                    Colors.grey[700],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            ElevatedButton.icon(
                                              onPressed:
                                                  _updateTeacherDescription,
                                              icon: const Icon(Icons.save),
                                              label: const Text('Save'),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.blue,
                                                foregroundColor: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 40),
                                ],
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.grey[50],
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: const Text(
                                  "This user doesn't have a teacher profile yet.",
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),

                          const SizedBox(height: 30),
                          Row(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 170),
                                child: Text(
                                  "   Classes",
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed:
                                    (user?.teacher != null &&
                                        classesError == null &&
                                        myClasses.isNotEmpty)
                                    ? () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                AllClassesPage(
                                                  myClasses: myClasses,
                                                  errorMessage: classesError,
                                                ),
                                          ),
                                        );
                                      }
                                    : null,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.black,
                                  padding: EdgeInsets.zero,
                                ),
                                child: const Text(
                                  "   See more",
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                              const Icon(
                                Icons.keyboard_arrow_right,
                                color: Colors.black,
                              ),
                            ],
                          ),
                          if (user?.teacher != null)
                            if (isClassesLoading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (classesError != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Text(
                                  classesError!,
                                  style: TextStyle(
                                    color: Colors.red.shade400,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            else if (myClasses.isNotEmpty)
                              Column(
                                children: myClasses.take(2).map((c) {
                                  final fallbackName =
                                      '${user?.firstName ?? ''} ${user?.lastName ?? ''}'
                                          .trim()
                                          .replaceAll(RegExp(r'\s{2,}'), ' ');
                                  final teacherDisplayName =
                                      (c.teacherName ?? fallbackName).trim();

                                  return ClassCard(
                                    id: c.id,
                                    className: c.className,
                                    teacherName: teacherDisplayName.isEmpty
                                        ? 'ไม่ทราบชื่อผู้สอน'
                                        : teacherDisplayName,
                                    rating: c.rating,
                                    enrolledLearner: c.enrolledLearners,
                                    imageUrl: (() {
                                      final image =
                                          c.bannerPictureUrl ?? c.bannerPicture;
                                      if (image == null || image.isEmpty) {
                                        return null;
                                      }
                                      return image;
                                    })(),
                                  );
                                }).toList(),
                              )
                            else
                              const Text('ยังไม่มีคลาสสำหรับผู้สอนคนนี้')
                          else
                            const SizedBox(height: 135),

                          const SizedBox(height: 20),

                          // Logout Button
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 30,
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _handleLogout,
                                icon: const Icon(Icons.logout, size: 24),
                                label: const Text(
                                  'ออกจากระบบ',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red[700],
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
    );
  }
}
