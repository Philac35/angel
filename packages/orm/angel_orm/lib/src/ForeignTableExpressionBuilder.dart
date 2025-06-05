import 'builder.dart';
import 'query.dart';


class ForeignTableSqlExpressionBuilder<T extends Query> implements SqlExpressionBuilder {
  final String tableName;
  final String foreignKey;
  final List<String> foreignTableColumns;
  final T _querySource; // Can be either Query or QueryWhere

  ForeignTableSqlExpressionBuilder({
    required this.tableName,
    required this.foreignKey,
    required this.foreignTableColumns,
    required T querySource,
  }) : _querySource = querySource;

  @override
  String build() {
    return '$tableName.$foreignKey';
  }

  @override
  String get columnName => foreignKey;

  @override
  List<String> get columnNames => foreignTableColumns;

  @override
  String? compile() {
    if (tableName.isEmpty || foreignKey.isEmpty || foreignTableColumns.isEmpty) {
      return null;
    }

    // Construct the SQL expression for multiple columns
    final conditions = foreignTableColumns.map((column) => '$tableName.$foreignKey = $column').join(' AND ');
    return conditions;
  }

  @override
  bool get hasValue => tableName.isNotEmpty && foreignKey.isNotEmpty && foreignTableColumns.isNotEmpty;

@override
  T get query {
    return _querySource;
  }

  @override
  String get substitution {
    // Construct the substitution string for multiple columns
    final conditions = foreignTableColumns.map((column) => '$tableName.$foreignKey = $column').join(' AND ');
    return conditions;
  }
}




/*

ForeignTableSqlExpressionBuilder  !generic
class ForeignTableSqlExpressionBuilder implements SqlExpressionBuilder {
  final String tableName;
  final String foreignKey;
  final List<String> foreignTableColumns; // List of columns in the foreign table
  final dynamic _querySource; // Can be either Query or QueryWhere

  ForeignTableSqlExpressionBuilder({
    required this.tableName,
    required this.foreignKey,
    required this.foreignTableColumns,
    required dynamic querySource,
  }) : _querySource = querySource;

  @override
  String build() {
    return '$tableName.$foreignKey';
  }



  @override
  // TODO: implement columnName
  String get columnName =>foreignKey;


  @override
  List<String> get columnNames => foreignTableColumns;

  @override
  String? compile() {
    // Build the SQL expression
    if (tableName.isEmpty || foreignKey.isEmpty || foreignTableColumns.isEmpty) {
      return null;
    }
    //return build();

    // Assuming foreignKey is a single column and foreignTableColumns is a list of columns
    // This is a simplified example; you might need to adjust based on your actual requirements
    return '$tableName.$foreignKey = ${foreignTableColumns.join(" AND $tableName.$foreignKey = ")}';
  }

  @override
  bool get hasValue => tableName.isNotEmpty && foreignKey.isNotEmpty  && foreignTableColumns.isNotEmpty;;


  @override
  Query get query {
    // Return the appropriate query instance
    return _querySource;
  }

  @override
  String get substitution =>  '$tableName.$foreignKey = ${foreignTableColumns.join(" AND $tableName.$foreignKey = ")}';

}
*/
