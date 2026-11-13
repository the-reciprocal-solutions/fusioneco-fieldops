/// The four maintenance record types, same names as technician_portal's
/// `OrderType` (domain/maintenance_record.dart). Only the identity lives here;
/// the theme colours each one (`FeOrderTypeColors.forType`). The FM screens
/// (FE-mobile.md Phase 3a) add the API paths when they need them.
enum OrderType { workOrder, preventive, reactive, annual }
