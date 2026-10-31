/// The signed-in admin-panel user (Admin, Vendor or Tenant role), as
/// `POST /api/auth/login` returns it under `user`.
class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.role,
    this.email,
    this.username,
    this.orgId,
    this.companyName,
  });

  final String id;
  final String name;
  final String role;
  final String? email;
  final String? username;
  final String? orgId;
  final String? companyName;

  /// Tolerant parse: ids may arrive as numbers or strings.
  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        role: '${json['role'] ?? ''}',
        email: json['email'] as String?,
        username: json['username'] as String?,
        orgId: json['orgId']?.toString(),
        companyName: json['companyName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'email': email,
        'username': username,
        'orgId': orgId,
        'companyName': companyName,
      };
}
