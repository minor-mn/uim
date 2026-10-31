/// Bindings for the parts of the tree-sitter C API that uim uses.
/// See third_party/tree-sitter/lib/include/tree_sitter/api.h.
library;

import 'dart:ffi';

final class TSParser extends Opaque {}

final class TSTree extends Opaque {}

final class TSLanguage extends Opaque {}

final class TSQuery extends Opaque {}

final class TSQueryCursor extends Opaque {}

final class TSPoint extends Struct {
  @Uint32()
  external int row;
  @Uint32()
  external int column;
}

final class TSNode extends Struct {
  @Array(4)
  external Array<Uint32> context;
  external Pointer<Void> id;
  external Pointer<TSTree> tree;
}

final class TSInputEdit extends Struct {
  @Uint32()
  external int startByte;
  @Uint32()
  external int oldEndByte;
  @Uint32()
  external int newEndByte;
  external TSPoint startPoint;
  external TSPoint oldEndPoint;
  external TSPoint newEndPoint;
}

final class TSQueryCapture extends Struct {
  external TSNode node;
  @Uint32()
  external int index;
}

final class TSQueryMatch extends Struct {
  @Uint32()
  external int id;
  @Uint16()
  external int patternIndex;
  @Uint16()
  external int captureCount;
  external Pointer<TSQueryCapture> captures;
}

const predicateDone = 0;
const predicateCapture = 1;
const predicateString = 2;

final class TSQueryPredicateStep extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int valueId;
}

@Native<Pointer<TSParser> Function()>()
external Pointer<TSParser> ts_parser_new();

@Native<Void Function(Pointer<TSParser>)>()
external void ts_parser_delete(Pointer<TSParser> parser);

@Native<Bool Function(Pointer<TSParser>, Pointer<TSLanguage>)>()
external bool ts_parser_set_language(
  Pointer<TSParser> parser,
  Pointer<TSLanguage> language,
);

@Native<
  Pointer<TSTree> Function(
    Pointer<TSParser>,
    Pointer<TSTree>,
    Pointer<Uint8>,
    Uint32,
  )
>()
external Pointer<TSTree> ts_parser_parse_string(
  Pointer<TSParser> parser,
  Pointer<TSTree> oldTree,
  Pointer<Uint8> string,
  int length,
);

@Native<Void Function(Pointer<TSTree>)>()
external void ts_tree_delete(Pointer<TSTree> tree);

@Native<Void Function(Pointer<TSTree>, Pointer<TSInputEdit>)>()
external void ts_tree_edit(Pointer<TSTree> tree, Pointer<TSInputEdit> edit);

@Native<TSNode Function(Pointer<TSTree>)>()
external TSNode ts_tree_root_node(Pointer<TSTree> tree);

@Native<Uint32 Function(TSNode)>()
external int ts_node_start_byte(TSNode node);

@Native<Uint32 Function(TSNode)>()
external int ts_node_end_byte(TSNode node);

@Native<TSPoint Function(TSNode)>()
external TSPoint ts_node_start_point(TSNode node);

@Native<TSPoint Function(TSNode)>()
external TSPoint ts_node_end_point(TSNode node);

@Native<
  Pointer<TSQuery> Function(
    Pointer<TSLanguage>,
    Pointer<Uint8>,
    Uint32,
    Pointer<Uint32>,
    Pointer<Uint32>,
  )
>()
external Pointer<TSQuery> ts_query_new(
  Pointer<TSLanguage> language,
  Pointer<Uint8> source,
  int length,
  Pointer<Uint32> errorOffset,
  Pointer<Uint32> errorType,
);

@Native<Void Function(Pointer<TSQuery>)>()
external void ts_query_delete(Pointer<TSQuery> query);

@Native<Uint32 Function(Pointer<TSQuery>)>()
external int ts_query_pattern_count(Pointer<TSQuery> query);

@Native<Uint32 Function(Pointer<TSQuery>)>()
external int ts_query_capture_count(Pointer<TSQuery> query);

@Native<Pointer<Uint8> Function(Pointer<TSQuery>, Uint32, Pointer<Uint32>)>()
external Pointer<Uint8> ts_query_capture_name_for_id(
  Pointer<TSQuery> query,
  int index,
  Pointer<Uint32> length,
);

@Native<Pointer<Uint8> Function(Pointer<TSQuery>, Uint32, Pointer<Uint32>)>()
external Pointer<Uint8> ts_query_string_value_for_id(
  Pointer<TSQuery> query,
  int index,
  Pointer<Uint32> length,
);

@Native<
  Pointer<TSQueryPredicateStep> Function(
    Pointer<TSQuery>,
    Uint32,
    Pointer<Uint32>,
  )
>()
external Pointer<TSQueryPredicateStep> ts_query_predicates_for_pattern(
  Pointer<TSQuery> query,
  int patternIndex,
  Pointer<Uint32> stepCount,
);

@Native<Pointer<TSQueryCursor> Function()>()
external Pointer<TSQueryCursor> ts_query_cursor_new();

@Native<Void Function(Pointer<TSQueryCursor>)>()
external void ts_query_cursor_delete(Pointer<TSQueryCursor> cursor);

@Native<Void Function(Pointer<TSQueryCursor>, Pointer<TSQuery>, TSNode)>()
external void ts_query_cursor_exec(
  Pointer<TSQueryCursor> cursor,
  Pointer<TSQuery> query,
  TSNode node,
);

@Native<Bool Function(Pointer<TSQueryCursor>, TSPoint, TSPoint)>()
external bool ts_query_cursor_set_point_range(
  Pointer<TSQueryCursor> cursor,
  TSPoint start,
  TSPoint end,
);

@Native<
  Bool Function(Pointer<TSQueryCursor>, Pointer<TSQueryMatch>, Pointer<Uint32>)
>()
external bool ts_query_cursor_next_capture(
  Pointer<TSQueryCursor> cursor,
  Pointer<TSQueryMatch> match,
  Pointer<Uint32> captureIndex,
);

@Native<Void Function(Pointer<TSQueryCursor>, Uint32)>()
external void ts_query_cursor_remove_match(
  Pointer<TSQueryCursor> cursor,
  int matchId,
);
