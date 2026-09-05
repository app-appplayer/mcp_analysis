import 'package:mcp_bundle/ports.dart';

/// Current actor role and permissions for authorization checks.
class RbacContext {
  const RbacContext({
    required this.actorId,
    required this.role,
    this.groups = const [],
  });
  final String actorId;
  final String role; // operator, engineer, admin
  final List<String> groups;
}

/// Enforces role-based access control.
class RbacPolicy {
  static const _permissions = <String, Set<String>>{
    'operator': {
      'list_specs',
      'view_spec',
      'execute',
      'view_job',
      'view_artifacts',
      'cancel_own_job',
    },
    'engineer': {
      'list_specs',
      'view_spec',
      'create_spec',
      'update_spec',
      'execute',
      'view_job',
      'view_artifacts',
      'cancel_own_job',
    },
    'admin': {
      'list_specs',
      'view_spec',
      'create_spec',
      'update_spec',
      'execute',
      'view_job',
      'view_artifacts',
      'cancel_own_job',
      'cancel_any_job',
      'view_audit',
      'manage_rbac',
    },
  };

  static const _roleHierarchy = <String, int>{
    'operator': 0,
    'engineer': 1,
    'admin': 2,
  };

  static const _groupRoleMapping = <String, String>{
    'admin': 'admin',
    'admins': 'admin',
    'engineer': 'engineer',
    'engineers': 'engineer',
    'operator': 'operator',
    'operators': 'operator',
  };

  /// Resolve the effective role considering group memberships.
  String _resolveEffectiveRole(RbacContext context) {
    var effectiveRole = context.role;
    var effectiveLevel = _roleHierarchy[effectiveRole] ?? 0;

    for (final group in context.groups) {
      final groupRole = _groupRoleMapping[group.toLowerCase()];
      if (groupRole != null) {
        final groupLevel = _roleHierarchy[groupRole] ?? 0;
        if (groupLevel > effectiveLevel) {
          effectiveRole = groupRole;
          effectiveLevel = groupLevel;
        }
      }
    }
    return effectiveRole;
  }

  /// Check if actor has permission for the given operation.
  Future<void> checkPermission({
    required RbacContext context,
    required String operation,
    String? resourceId,
  }) async {
    final effectiveRole = _resolveEffectiveRole(context);
    final rolePermissions = _permissions[effectiveRole];
    if (rolePermissions == null || !rolePermissions.contains(operation)) {
      throw AnalysisError(
        code: 'governance.unauthorized',
        message:
            'Actor "${context.actorId}" with role "$effectiveRole" lacks permission for "$operation"',
        details: {
          'actorId': context.actorId,
          'role': effectiveRole,
          'groups': context.groups,
          'operation': operation,
        },
      );
    }
  }

  /// Check if actor can execute a Spec.
  Future<void> canExecute(RbacContext context, String specId) async {
    await checkPermission(
      context: context,
      operation: 'execute',
      resourceId: specId,
    );
  }

  /// Check if actor can create/update a Spec.
  Future<void> canManageSpec(RbacContext context) async {
    await checkPermission(context: context, operation: 'create_spec');
  }

  /// Check if actor can view artifacts.
  Future<void> canViewArtifacts(RbacContext context) async {
    await checkPermission(context: context, operation: 'view_artifacts');
  }

  /// Check if actor can view audit logs.
  Future<void> canViewAudit(RbacContext context) async {
    await checkPermission(context: context, operation: 'view_audit');
  }
}
