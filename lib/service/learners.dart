import 'package:tutorium_frontend/service/api_client.dart';
import 'package:tutorium_frontend/util/local_storage.dart';

class Learner {
  final int? id;
  final int flagCount;
  final int userId;
  final List<String> interestedCategories;

  const Learner({
    this.id,
    required this.flagCount,
    required this.userId,
    this.interestedCategories = const [],
  });

  factory Learner.fromJson(Map<String, dynamic> json) {
    final interested = _extractInterestedCategories(json);
    return Learner(
      id: json['ID'] ?? json['id'],
      flagCount: json['flag_count'] ?? 0,
      userId: json['user_id'] ?? 0,
      interestedCategories: interested,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'flag_count': flagCount,
      'user_id': userId,
    };
  }

  static final ApiClient _client = ApiClient();

  static Future<List<Learner>> fetchAll({Map<String, dynamic>? query}) async {
    final response = await _client.getJsonList(
      '/learners',
      queryParameters: query,
    );
    return response.map(Learner.fromJson).toList();
  }

  static Future<Learner> fetchById(int id) async {
    final response = await _client.getJsonMap('/learners/$id');
    return Learner.fromJson(response);
  }

  static Future<Learner> create(Learner learner) async {
    final response = await _client.postJsonMap(
      '/learners',
      body: learner.toJson(),
    );
    return Learner.fromJson(response);
  }

  static Future<void> delete(int id) async {
    await _client.delete('/learners/$id');
  }

  static List<String> _extractInterestedCategories(Map<String, dynamic> json) {
    final interested = json['Interested'];
    if (interested is List) {
      final names =
          interested
              .map((raw) {
                if (raw is Map<String, dynamic>) {
                  final category = raw['ClassCategory'];
                  if (category is Map<String, dynamic>) {
                    final name = category['class_category'] ?? category['name'];
                    return name?.toString().trim();
                  }
                }
                return null;
              })
              .where((value) => value != null && value!.isNotEmpty)
              .map((value) => value!)
              .toSet()
              .toList(growable: false)
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    }

    final direct = json['interested_categories'] ?? json['categories'];
    if (direct is List) {
      final names =
          direct
              .map((value) => value?.toString().trim())
              .where((value) => value != null && value!.isNotEmpty)
              .map((value) => value!)
              .toSet()
              .toList(growable: false)
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    }

    return const [];
  }
}

class LearnerInterestState {
  final List<String> categories;

  const LearnerInterestState({required this.categories});

  factory LearnerInterestState.fromJson(Map<String, dynamic> json) {
    final categories = json['categories'];
    if (categories is List) {
      final normalized =
          categories
              .map((value) => value?.toString().trim())
              .where((value) => value != null && value!.isNotEmpty)
              .map((value) => value!)
              .toSet()
              .toList(growable: false)
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return LearnerInterestState(categories: normalized);
    }
    return const LearnerInterestState(categories: []);
  }

  factory LearnerInterestState.fromLearnerDoc(Map<String, dynamic> json) {
    final learner = Learner.fromJson(json);
    return LearnerInterestState(categories: learner.interestedCategories);
  }
}

class RecommendedClassesResponse {
  RecommendedClassesResponse({
    required this.recommendedFound,
    required this.recommendedClasses,
    required this.remainingClasses,
  });

  final bool recommendedFound;
  final List<Map<String, dynamic>> recommendedClasses;
  final List<Map<String, dynamic>> remainingClasses;

  factory RecommendedClassesResponse.fromJson(Map<String, dynamic> json) {
    final recommended =
        json['recommended_classes'] as List<dynamic>? ?? const <dynamic>[];
    final remaining =
        json['remaining_classes'] as List<dynamic>? ?? const <dynamic>[];
    return RecommendedClassesResponse(
      recommendedFound: json['recommended_found'] == true,
      recommendedClasses: recommended
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
      remainingClasses: remaining
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
    );
  }
}

class LearnerInterestService {
  static final ApiClient _client = ApiClient();

  static Future<LearnerInterestState> fetchInterests(int learnerId) async {
    final response = await _client.getJsonMap(
      '/learners/$learnerId/interests',
      headers: await _authHeaders(),
    );
    return LearnerInterestState.fromJson(response);
  }

  static Future<LearnerInterestState> addInterests(
    int learnerId,
    List<int> categoryIds,
  ) async {
    if (categoryIds.isEmpty) {
      return fetchInterests(learnerId);
    }
    final response = await _client.postJsonMap(
      '/learners/$learnerId/interests',
      headers: await _authHeaders(),
      body: {'class_category_ids': categoryIds},
    );
    return LearnerInterestState.fromLearnerDoc(response);
  }

  static Future<LearnerInterestState> removeInterests(
    int learnerId,
    List<int> categoryIds,
  ) async {
    if (categoryIds.isEmpty) {
      return fetchInterests(learnerId);
    }
    final response = await _client.delete(
      '/learners/$learnerId/interests',
      headers: await _authHeaders(),
      body: {'class_category_ids': categoryIds},
    );

    if (response is Map<String, dynamic>) {
      return LearnerInterestState.fromLearnerDoc(response);
    }

    return fetchInterests(learnerId);
  }

  static Future<RecommendedClassesResponse> fetchRecommendations(
    int learnerId,
  ) async {
    final response = await _client.getJsonMap(
      '/learners/$learnerId/recommended',
      headers: await _authHeaders(),
    );
    return RecommendedClassesResponse.fromJson(response);
  }

  static Future<Map<String, String>> _authHeaders() async {
    final token = await LocalStorage.getToken();
    if (token == null || token.isEmpty) {
      return const {};
    }
    return {'Authorization': 'Bearer $token'};
  }
}
