module "moonscript.compile", package.seeall

util = require "moonscript.util"
data = require "moonscript.data"
dump = require "moonscript.dump"

require "moonscript.compile.format"

import reversed from util
import ntype from data
import concat, insert from table

export line_compile

constructor_name = "new"

line_compile =
  raw: (node) =>
    _, text = unpack node
    @add text

  declare: (node) =>
    _, names = unpack node
    undeclared = @declare names
    if #undeclared > 0
      with @line "local "
        \append_list names, ", "

  assign: (node) =>
    _, names, values = unpack node

    undeclared = @declare names
    declare = "local "..concat(undeclared, ", ")

    if @is_stm values
      @add declare if #undeclared > 0
      if cascading[ntype(values)]
        decorate = (value) ->
          {"assign", names, {value}}

        @stm values, decorate
      else
        error "Assigning unsupported statement"
    else
      has_fndef = false
      i = 1
      while i <= #values
        if ntype(values[i]) == "fndef"
          has_fndef = true
        i = i +1

      with @line!
        if #undeclared == #names and not has_fndef
          \append declare
        else
          @add declare if #undeclared > 0
          \append_list [@value name for name in *names], ", "

        \append " = "
        \append_list [@value v for v in *values], ", "

  update: (node) =>
    _, name, op, exp = unpack node
    op_final = op\match "(.)="
    error"unknown op: "..op if not op_final
    @stm {"assign", {name}, {{"exp", name, op_final, exp}}}

  return: (node) =>
    @line "return ", @value node[2]

  break: (node) =>
    "break"

  import: (node) =>
    _, names, source = unpack node

    to_bind = {}
    get_name = (name) ->
      if ntype(name) == ":"
        tmp = @name name[2]
        to_bind[tmp] = true
        tmp
      else
        @name name

    final_names = [get_name n for n in *names]
    @put_name name for name in *final_names

    get_value = (name) ->
      if to_bind[name]
        moonlib.bind source, name
      else
        source.."."..name

    -- from constant expression, put it on one line
    if type(source) == "string"
      values = [get_value name for name in *final_names]
      line = with @line "local ", concat(final_names, ", "), " = "
        \append_list values, ", "
      return line

    @add @line "local ", concat(final_names, ", ")
    with @block "do"
      source = \init_free_var "table", source
      \stm {"assign", {name}, {get_value name}} for name in *final_names

  if: (node, ret) =>
    cond, block = node[2], node[3]
    root = with @block @line "if ", @value(cond), " then"
      \stms block, ret

    current = root
    add_clause = (clause)->
      type = clause[1]
      i = 2
      next = if type == "else"
        @block "else"
      else
        i += 1
        @block @line "elseif ", @value(clause[2]), " then"

      next\stms clause[i], ret

      current.next = next
      current = next

    add_clause cond for cond in *node[4:]
    root

  while: (node) =>
    _, cond, block = unpack node

    out = if is_non_atomic cond
      with @block "while true do"
        \stm {"if", {"not", cond}, {{"break"}}}
    else
      @block @line "while ", @value(cond), " do"

    out\stms block
    out

  for: (node) =>
    _, name, bounds, block = unpack node
    loop = @line "for ", @name(name), " = ", @value({"explist", unpack bounds}), " do"
    with @block loop
      \stms block

  -- for x in y ...
  -- {"foreach", {names...}, exp, body}
  foreach: (node) =>
    _, names, exp, block = unpack node

    if ntype(exp) == "unpack"
      iter = exp[2]
      loop = with @block!
        items_tmp = \free_name "item", true
        -- handle unpacked slices directly
        bounds = if is_slice iter
          slice = iter[#iter]
          table.remove iter
          table.remove slice, 1

          slice[2] = if slice[2] and slice[2] != ""
            max_tmp = \init_free_var "max", slice[2]
            {"exp", max_tmp, "<", 0
              "and", {"length", items_tmp}, "+", max_tmp
              "or", max_tmp }
          else
            {"length", items_tmp}

          slice
        else
          print "tmp", items_tmp
          {1, {"length", items_tmp}}

        index_tmp = \free_name "index"

        \stm {"assign", {items_tmp}, {iter}}

        block = [s for s in *block]
        insert block, 1, {"assign", names, {
          {"chain", items_tmp, {"index", index_tmp}}
        }}

        \stm {"for", index_tmp, bounds, block }

      return loop

    loop = with @line!
      \append "for "
      \append_list names, ", "
      \append " in ", @value(exp), " do"

    with @block loop
      \stms block

  export: (node) =>
    _, names = unpack node
    @put_name name for name in *names when type(name) == "string"
    nil

  class: (node) =>
    _, name, parent_val, tbl = unpack node

    constructor = nil
    final_properties = {}

    -- organize constructor and everything else
    find_special = (name, value) ->
      if name == constructor_name
        constructor = value
      else
        insert final_properties, {name, value}

    find_special unpack entry for entry in *tbl[2]
    tbl[2] = final_properties

    -- synthesize constructor if needed
    if not constructor
      constructor = {"fndef", {"..."}, "fat", {
        {"if", parent_loc, {
          {"chain", "super", {"call", {"..."}}}
        }}
      }}

    -- organize constructor arguments
    -- extract self arguments
    self_args = {}
    get_initializers = (arg) ->
      if ntype(arg) == "self"
        arg = arg[2]
        insert self_args, arg
      arg

    constructor[2] = [get_initializers arg for arg in *constructor[2]]
    constructor[3] = "fat"
    body = constructor[4]

    -- insert self assigning arguments
    dests = [{"self", name} for name in *self_args]
    insert body, 1, {"assign", dests, self_args} if #self_args > 0

    -- now create the class's initialization block
    parent_loc = @free_name "parent", false

    def_scope = with @block!
      parent_val = @value parent_val if parent_val != ""
      \put_name parent_loc

      .header = @line "(function(", parent_loc, ")"
      .footer = @line "end)(", parent_val, ")"

      \set "super", (block, chain) ->
        calling_name = block\get"current_block"
        slice = [item for item in *chain[3:]]
        -- inject self
        slice[1] = {"call", {"self", unpack slice[1][2]}}

        act = if ntype(calling_name) != "value" then "index" else "dot"
        {"chain", parent_loc, {act, calling_name}, unpack slice}

      -- the metatable holding all the class methods
      base_name = \init_free_var "base", tbl
      \stm {"assign", { {"chain", base_name, {"dot", "__index"}} }, { base_name }}

      -- handle super class if there is one
      \stm {"if", parent_loc,
        {{"chain", "setmetatable", {"call",
        {base_name, {"chain", "getmetatable",
          {"call", {parent_loc}}, {"dot", "__index"}}}}}}}

      -- the class object that is returned
      cls = {"table", {
        {"__init", constructor}
      }}

      -- the class's meta table, gives us call and access to base methods
      cls_mt = {"table", {
        {"__index", base_name}
        {"__call", {"fndef", {"mt", "..."}, "slim", {
            {"raw", ("local self = setmetatable({}, %s)")\format(base_name)}
            {"chain", "mt.__init", {"call", {"self", "..."}}}
            "self"
          }}}
      }}

      cls_name = \init_free_var "class", {
        "chain", "setmetatable", {"call", {cls, cls_mt}}
      }

      \stm {"assign"
        {{"chain", base_name, {"dot", "__class"}}}
        {cls_name}
      }

      \stm {"return", cls_name}

    @stm {"declare", {name}}
    @line name, " = ", def_scope

  comprehension: (node, action) =>
    _, exp, clauses = unpack node

    if not action
      action = (exp) -> exp

    statement = action exp
    build_clause = (clause) ->
      t = clause[1]
      statement = if t == "for"
        _, names, iter = unpack clause
        {"foreach", names, iter, {statement}}
      elseif t == "when"
        _, cond = unpack clause
        {"if", cond, {statement}}
      else
        error "Unknown comprehension clause: "..t

    build_clause clause for i, clause in reversed clauses
    @stm statement


  with: (node, ret) =>
    _, exp, block = unpack node

    with @block!
      var = \init_free_var "with", exp
      @set "scope_var", var
      \stms block
      \stm ret var if ret

