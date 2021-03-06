#----------------------------------------------------------------------
package DBIx::DataModel::Statement;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use List::Util       qw/min/;
use List::MoreUtils  qw/firstval any/;
use Scalar::Util     qw/weaken dualvar/;
use POSIX            qw/LONG_MAX/;
use Clone            qw/clone/;
use Carp::Clan       qw[^(DBIx::DataModel::|SQL::Abstract)];
use Try::Tiny        qw/try catch/;
use Module::Load     qw/load/;
use mro              qw/c3/;

use DBIx::DataModel;
use DBIx::DataModel::Meta::Utils qw/define_readonly_accessors does/;
use namespace::clean;

#----------------------------------------------------------------------
# internals
#----------------------------------------------------------------------

use overload

  # overload the stringification operator so that Devel::StackTrace is happy;
  # also useful to show the SQL (if in sqlized state)
  '""' => sub {
    my $self = shift;
    my $string = try {my ($sql, @bind) = $self->sql;
                       __PACKAGE__ . "($sql // " . join(", ", @bind) . ")"; }
              || overload::StrVal($self);
  }
;


# sequence of states. Stored as dualvars for both ordering and printing
use constant {
  NEW      => dualvar(1, "new"     ),
  REFINED  => dualvar(2, "refined" ),
  SQLIZED  => dualvar(3, "sqlized" ),
  PREPARED => dualvar(4, "prepared"),
  EXECUTED => dualvar(5, "executed"),
};



#----------------------------------------------------------------------
# PUBLIC METHODS
#----------------------------------------------------------------------

sub new {
  my ($class, $source, %other_args) = @_;

  # check $source
  $source 
    && $source->isa('DBIx::DataModel::Source')
    or croak "invalid source for DBIx::DataModel::Statement->new()";

  # build the object
  my $self = bless {status           => NEW,
                    args             => {},
                    pre_bound_params => {},
                    bound_params     => [],
                    source           => $source}, $class;

  # add placeholder_regex
  my $prefix = $source->schema->{placeholder_prefix};
  $self->{placeholder_regex} = qr/^\Q$prefix\E(.+)/;

  # parse remaining args, if any
  $self->refine(%other_args) if %other_args;

  return $self;
}


# accessors
define_readonly_accessors( __PACKAGE__, qw/source status/);

# proxy methods
sub meta_source {shift->{source}->metadm}
sub schema      {shift->{source}->schema}


# back to the original state
sub reset {
  my ($self, %other_args) = @_;

  my $new = (ref $self)->new($self->{source}, %other_args);
  %$self = (%$new);

  return $self;
}


sub arg {
  my ($self, $arg_name) = @_;

  my $args = $self->{args} || {};
  return $args->{$arg_name};
}



#----------------------------------------------------------------------
# PUBLIC METHODS IN RELATION WITH SELECT()
#----------------------------------------------------------------------


sub sql {
  my ($self) = @_;

  $self->status >= SQLIZED
    or croak "can't call sql() when in status ". $self->status;

  return wantarray ? ($self->{sql}, @{$self->{bound_params}})
                   : $self->{sql};
}


sub bind {
  my ($self, @args) = @_;

  # arguments can be a list, a hashref or an arrayref
  if (@args == 1) {
    if (does $args[0], 'HASH') {
      @args = %{$args[0]};
    }
    elsif (does $args[0], 'ARRAY') {
      my $i = 0; @args = map {($i++, $_)} @{$args[0]};
    }
    else {
      croak "unexpected arg type to bind()";
    }
  }
  elsif (@args == 3) { # name => value, \%datatype (see L<DBI/bind_param>)
    # transform into ->bind($name => [$value, \%datatype])
    @args = ($args[0], [$args[1], $args[2]]);
  }
  elsif (@args % 2 == 1) {
    croak "odd number of args to bind()";
  }

  # do bind (different behaviour according to status)
  my %args = @args;
  if ($self->status < SQLIZED) {
    while (my ($k, $v) = each %args) {
      $self->{pre_bound_params}{$k} = $v;
    }
  }
  else {
    while (my ($k, $v) = each %args) {
      my $indices = $self->{param_indices}{$k} 
        or next; # silently ignore that binding (named placeholder unused)
      $self->{bound_params}[$_] = $v foreach @$indices;
    }
  }

  # THINK : probably we should check here that $args{__schema}, if present,
  # is the same as $self->schema (same database connection) ... but how
  # to check for "sameness" on database handles ?

  return $self;
}


sub refine {
  my ($self, %more_args) = @_;

  $self->status <= REFINED
    or croak "can't refine() when in status " . $self->status;
  $self->{status} = REFINED;

  my $args = $self->{args};

  while (my ($k, $v) = each %more_args) {

  SWITCH:
    for ($k) {

      # -where : combine with previous 'where' clauses in same statement
      /^-where$/ and do {
        my $sqla = $self->schema->sql_abstract;
        $args->{-where} = $sqla->merge_conditions($args->{-where}, $v);
        last SWITCH;
      };

      # -fetch : special select() on primary key
      /^-fetch$/ and do {
        # build a -where clause on primary key
        my $primary_key = ref($v) ? $v : [$v];
        my @pk_columns  = $self->meta_source->primary_key;
        @pk_columns
          or croak "fetch: no primary key in source " . $self->meta_source;
        @pk_columns == @$primary_key
          or croak sprintf "fetch from %s: primary key should have %d values",
                           $self->meta_source, scalar(@pk_columns);
        List::MoreUtils::all {defined $_} @$primary_key
          or croak "fetch from " . $self->meta_source . ": "
                 . "undefined val in primary key";

        my %where = ();
        @where{@pk_columns} = @$primary_key;
        my $sqla = $self->schema->sql_abstract;
        $args->{-where} = $sqla->merge_conditions($args->{-where}, \%where);

        # want a single record as result
        $args->{-result_as} = "firstrow";

        last SWITCH;
      };

      # -columns : store in $self->{args}{-columns}; can restrict previous list
      /^-columns$/ and do {
        my @cols = does($v, 'ARRAY') ? @$v : ($v);
        if (my $old_cols = $args->{-columns}) {
          unless (@$old_cols == 1 && $old_cols->[0] eq '*' ) {
            foreach my $col (@cols) {
              any {$_ eq $col} @$old_cols
                or croak "can't restrict -columns on '$col' (was not in the) "
                       . "previous -columns list";
            }
          }
        }
        $args->{-columns} = \@cols;
        last SWITCH;
      };


      # other args are just stored, they will be used later
      /^-( order_by       | group_by  | having    | for
         | union(?:_all)? | intersect | except    | minus
         | result_as      | post_SQL  | pre_exec  | post_exec  | post_bless
         | limit          | offset    | page_size | page_index
         | column_types   | prepare_attrs         | dbi_prepare_method
         | _left_cols     | where_on              | join_with_USING
         )$/x
         and do {$args->{$k} = $v; last SWITCH};

      # TODO : this hard-coded list of args should be more abstract

      # otherwise
      croak "invalid arg : $k";

    } # end SWITCH
  } # end while

  return $self;
}




sub sqlize {
  my ($self, @args) = @_;

  $self->status < SQLIZED
    or croak "can't sqlize() when in status ". $self->status;

  # merge new args into $self->{args}
  $self->refine(@args) if @args;

  # shortcuts
  my $args         = $self->{args};
  my $meta_source  = $self->meta_source;
  my $source_where = $meta_source->{where};
  my $sql_abstract = $self->schema->sql_abstract;
  my $result_as    = $args->{-result_as} || "";

  # build arguments for SQL::Abstract::More
  $self->refine(-where => $source_where) if $source_where;
  my @args_to_copy = qw/-columns -where
                        -union -union_all -intersect -except -minus
                        -order_by -group_by -having
                        -limit -offset -page_size -page_index/;
  my %sqla_args = (-from         => clone($self->source->db_from),
                   -want_details => 1);
  defined $args->{$_} and $sqla_args{$_} = $args->{$_} for @args_to_copy;
  $sqla_args{-columns} ||= $meta_source->default_columns;
  $sqla_args{-limit}   ||= 1
    if $result_as eq 'firstrow' && $self->schema->autolimit_firstrow;

  # "-for" (e.g. "update", "read only")
  if ($result_as ne 'subquery') {
    if ($args->{-for}) {
      $sqla_args{-for} = $args->{-for};
    }
    elsif (!exists $args->{-for}) {
      $sqla_args{-for} = $self->schema->select_implicitly_for;
    }
  }

  # "where_on" : conditions to be added in joins
  if (my $where_on = $args->{-where_on}) {
    # check proper usage
    does $sqla_args{-from}, 'ARRAY'
      or croak "datasource for '-where_on' was not a join";

    # retrieve components of the join and check again for proper usage
    my ($join_op, $first_table, @other_join_args) = @{$sqla_args{-from}};
    $join_op eq '-join'
      or croak "datasource for '-where_on' was not a join";

    # reverse index (table_name => $join_hash)
    my %by_dest_table = reverse @other_join_args;

    # insert additional conditions into appropriate places
    while (my ($table, $additional_cond) = each %$where_on) {
      my $join_cond = $by_dest_table{$table}
        or croak "-where_on => {'$table' => ..}: this table is not in the join";
      $join_cond->{condition}
        = $sql_abstract->merge_conditions($join_cond->{condition},
                                          $additional_cond);
      delete $join_cond->{using};
    }

    # TODO: should be able to use paths and aliases as keys, instead of
    # database table names.
    # TOCHECK: is this stuff still compatible with the bind() method ?
  }

  # adjust join conditions for ON clause or for USING clause
  if (does $sqla_args{-from}, 'ARRAY') {
    $sqla_args{-from}[0] eq '-join'
      or croak "datasource is an arrayref but does not start with -join";
    my $join_with_USING
      = exists $args->{-join_with_USING} ? $args->{-join_with_USING}
                                         : $self->schema->{join_with_USING};
    for (my $i = 2; $i < @{$sqla_args{-from}}; $i += 2) {
      my $join_cond = $sqla_args{-from}[$i];
      if ($join_with_USING) {
        delete $join_cond->{condition} if $join_cond->{using};
      }
      else {
        delete $join_cond->{using};
      }
    }
  }

  # generate SQL
  my $sqla_result = $sql_abstract->select(%sqla_args);

  # maybe post-process the SQL
  if ($args->{-post_SQL}) {
    ($sqla_result->{sql}, @{$sqla_result->{bind}})
      = $args->{-post_SQL}->($sqla_result->{sql}, @{$sqla_result->{bind}});
  }

  # keep $sql / @bind / aliases in $self, and set new status
  $self->{bound_params} = $sqla_result->{bind};
  $self->{$_} = $sqla_result->{$_} for qw/sql aliased_tables aliased_columns/;
  $self->{status}       = SQLIZED;

  # analyze placeholders, and replace by pre_bound params if applicable
  if (my $regex = $self->{placeholder_regex}) {
    for (my $i = 0; $i < @{$self->{bound_params}}; $i++) {
      $self->{bound_params}[$i] =~ $regex 
        and push @{$self->{param_indices}{$1}}, $i;
    }
  }
  $self->bind($self->{pre_bound_params}) if $self->{pre_bound_params};

  # compute callback to apply to data rows
  my $callback = $self->{args}{-post_bless};
  weaken(my $weak_self = $self);   # weaken to avoid a circular ref in closure
  $self->{row_callback} = sub {
    my $row = shift;
    $weak_self->bless_from_DB($row);
    $callback->($row) if $callback;
  };

  return $self;
}



sub prepare {
  my ($self, @args) = @_;

  my $meta_source = $self->meta_source;

  $self->sqlize(@args) if @args or $self->status < SQLIZED;

  $self->status == SQLIZED
    or croak "can't prepare() when in status " . $self->status;

  # log the statement and bind values
  $self->schema->_debug("PREPARE $self->{sql} / @{$self->{bound_params}}");

  # call the database
  my $dbh          = $self->schema->dbh or croak "Schema has no dbh";
  my $method       = $self->{args}{-dbi_prepare_method}
                  || $self->schema->dbi_prepare_method;
  my @prepare_args = ($self->{sql});
  if (my $prepare_attrs = $self->{args}{-prepare_attrs}) {
    push @prepare_args, $prepare_attrs;
  }
  $self->{sth}  = $dbh->$method(@prepare_args);

  # new status and return
  $self->{status} = PREPARED;
  return $self;
}


sub sth {
  my ($self) = @_;

  $self->prepare              if $self->status < PREPARED;
  return $self->{sth};
}



sub execute {
  my ($self, @bind_args) = @_;

  # if not prepared yet, prepare it
  $self->prepare              if $self->status < PREPARED;

  # TODO: DON'T REMEMBER why the line below was here. Keep it around for a while ...
  push @bind_args, offset => $self->{offset}  if $self->{offset};

  $self->bind(@bind_args)      if @bind_args;

  # shortcuts
  my $args = $self->{args};
  my $sth  = $self->sth;

  # previous row_count, row_num and reuse_row are no longer valid
  delete $self->{reuse_row};
  delete $self->{row_count};
  $self->{row_num} = $self->offset;

  # pre_exec callback
  $args->{-pre_exec}->($sth)   if $args->{-pre_exec};

  # check that all placeholders were properly bound to values
  my @unbound;
  while (my ($k, $indices) = each %{$self->{param_indices} || {}}) {
    exists $self->{bound_params}[$indices->[0]] or push @unbound, $k;
  }
  not @unbound 
    or croak "unbound placeholders (probably a missing foreign key) : "
            . CORE::join(", ", @unbound);

  # bind parameters and execute
  my $sqla = $self->schema->sql_abstract;
  $sqla->bind_params($sth, @{$self->{bound_params}});
  $sth->execute;

  # post_exec callback
  $args->{-post_exec}->($sth)  if $args->{-post_exec};

  $self->{status} = EXECUTED;
  return $self;
}





my %cache_result_class;

sub select {
  my $self = shift;

  $self->refine(@_) if @_;

  my $arg_result_as = $self->arg(-result_as) || 'rows';

 SWITCH:
  my ($result_as, @subclass_args)
    = does($arg_result_as, 'ARRAY') ? @$arg_result_as : ($arg_result_as);

  # historically,some kinds of results accepted various aliases
  $result_as =~ s/^flat(?:_array|)$/flat_arrayref/;
  $result_as =~ s/^arrayref$/rows/;
  $result_as =~ s/^fast-statement$/fast_statement/;

  for ($result_as) {
    my $subclass = $cache_result_class{$_}
               ||= $self->_find_result_class($_)
      or croak "didn't find any ResultAs subclass to implement -result_as => '$_'";
    my $result_maker = $subclass->new(@subclass_args);
    return $result_maker->get_result($self);
  }
}


sub row_count {
  my ($self) = @_;

  if (! exists $self->{row_count}) {
    $self->sqlize if $self->status < SQLIZED;
    my ($sql, @bind) = $self->sql;

    # get syntax used for LIMIT clauses ...
    my $sqla = $self->schema->sql_abstract;
    my ($limit_sql, undef, undef) = $sqla->limit_offset(0, 0);
    $limit_sql =~ s/([()?*])/\\$1/g;

    # ...and use it to remove the LIMIT clause and associated bind vals, if any
    if ($limit_sql =~ /ROWNUM/) { # special case for Oracle syntax, complex ...
                                  # see source code of SQL::Abstract::More
      $limit_sql =~ s/%s/(.*)/;
      if ($sql =~ s/^$limit_sql/$1/) {
        splice @bind, -2;
      }
    }
    elsif ($sql =~ s[\b$limit_sql][]i) { # regular LIMIT/OFFSET syntaxes
      splice @bind, -2;
    }

    # decide if the SELECT COUNT should wrap the original SQL in a subquery;
    # this is needed with clauses like below that change the number of rows
    my $should_wrap = $sql =~ /\b(UNION|INTERSECT|MINUS|EXCEPT|DISTINCT)\b/i;

    # if no wrap required, attempt to directly substitute COUNT(*) for the 
    # column names ...but if it fails, wrap anyway
    $should_wrap ||= ! ($sql =~ s[^SELECT\b.*?\bFROM\b][SELECT COUNT(*) FROM]i);

    # wrap SQL if needed, using  a subquery alias because it's required for 
    # some DBMS (like PostgreSQL)
    $should_wrap and  $sql = "SELECT COUNT(*) FROM "
                           . $sqla->table_alias("( $sql )", "count_wrapper");

    # log the statement and bind values
    $self->schema->_debug("PREPARE $sql / @bind");

    # call the database
    my $dbh    = $self->schema->dbh or croak "Schema has no dbh";
    my $method = $self->schema->dbi_prepare_method;
    my $sth    = $dbh->$method($sql);
    $sth->execute(@bind);
    ($self->{row_count}) = $sth->fetchrow_array;
    $sth->finish;
  }

  return $self->{row_count};
}


sub row_num {
  my ($self) = @_;
  return $self->{row_num};
}

sub next {
  my ($self, $n_rows) = @_;

  $self->execute if $self->status < EXECUTED;

  my $sth      = $self->sth            or croak "absent sth in statement";
  my $callback = $self->{row_callback} or croak "absent callback in statement";

  if (not defined $n_rows) {  # if user wants a single row
    # fetch a single record, either into the reusable row, or into a fresh hash
    my $row = $self->{reuse_row} ? ($sth->fetch ? $self->{reuse_row} : undef)
                                 : $sth->fetchrow_hashref;
    if ($row) {
      $callback->($row);
      $self->{row_num} +=1;
    }
    return $row;
  }
  else {                      # if user wants an arrayref of size $n_rows
    $n_rows > 0            or croak "->next() : invalid argument, $n_rows";
    not $self->{reuse_row} or croak "reusable row, cannot retrieve several";
    my @rows;
    while ($n_rows--) {
      my $row = $sth->fetchrow_hashref or last;
      push @rows, $row;
    }
    $callback->($_) foreach @rows;
    $self->{row_num} += @rows;
    return \@rows;
  }

  # NOTE: ->next() returns a $row, while ->next(1) returns an arrayref of 1 row
}


sub all {
  my ($self) = @_;

  # just call next() with a huge number
  return $self->_next_and_finish(POSIX::LONG_MAX);
}


sub page_size   { shift->{args}{-page_size}  || POSIX::LONG_MAX  }
sub page_index  { shift->{args}{-page_index} || 1                }
sub offset      { shift->{offset}            || 0                }


sub page_count {
  my ($self) = @_;

  my $row_count = $self->row_count or return 0;
  my $page_size = $self->page_size || 1;

  return int(($row_count - 1) / $page_size) + 1;
}


sub page_boundaries {
  my ($self) = @_;

  my $first = $self->offset + 1;
  my $last  = min($self->row_count, $first + $self->page_size - 1);
  return ($first, $last);
}


sub page_rows {
  my ($self) = @_;
  return $self->_next_and_finish($self->page_size);
}


sub bless_from_DB {
  my ($self, $row) = @_;

  # inject ref to $schema if in multi-schema mode or if temporary
  # db_schema is set
  my $schema = $self->schema;
  $row->{__schema} = $schema unless $schema->{is_singleton}
                                 && !$schema->{db_schema};

  # bless into appropriate class
  bless $row, $self->meta_source->class;
  # apply handlers
  $self->{from_DB_handlers} or $self->_compute_from_DB_handlers;
  while (my ($column_name, $handler) 
           = each %{$self->{from_DB_handlers}}) {
    exists $row->{$column_name}
      and $handler->($row->{$column_name}, $row, $column_name, 'from_DB');
  }

  return $row;
}


sub headers {
  my $self = shift;

  $self->status == EXECUTED
    or $self->execute(@_);

  my $hash_key_name = $self->sth->{FetchHashKeyName} || 'NAME';
  return @{$self->sth->{$hash_key_name}};
}


sub finish {
  my $self = shift;
  $self->sth->finish;
}


sub make_fast {
  my ($self) = @_;

  $self->status == EXECUTED
    or croak "cannot make_fast() when in state " . $self->status;

  # create a reusable hash and bind_columns to it (see L<DBI/bind_columns>)
  my %row;
  $self->sth->bind_columns(\(@row{$self->headers}));
  $self->{reuse_row} = \%row;
}


#----------------------------------------------------------------------
# PRIVATE METHODS IN RELATION WITH SELECT()
#----------------------------------------------------------------------

sub _forbid_callbacks {
  my ($self, $subclass) = @_;

  my $callbacks = CORE::join ", ", grep {$self->arg($_)} 
                                        qw/-pre_exec -post_exec -post_bless/;
  if ($callbacks) {
    $subclass =~ s/^.*:://;
    croak "$callbacks incompatible with -result_as=>'$subclass'";
  }
}



sub _next_and_finish {
  my $self = shift;
  my $row_or_rows = $self->next( @_ ); # pass original parameters
  $self->finish;
  return $row_or_rows;
}

sub _compute_from_DB_handlers {
  my ($self) = @_;
  my $meta_source    = $self->meta_source;
  my $meta_schema    = $self->schema->metadm;
  my %handlers       = $meta_source->_consolidate_hash('column_handlers');
  my %aliased_tables = $meta_source->aliased_tables;

  # iterate over aliased_columns
  while (my ($alias, $column) = each %{$self->{aliased_columns} || {}}) {
    my $table_name;
    $column =~ s{^([^()]+)     # supposed table name (without parens)
                  \.           # followed by a dot
                  (?=[^()]+$)  # followed by supposed col name (without parens)
                }{}x
      and $table_name = $1;
    if (!$table_name) {
      $handlers{$alias} = $handlers{$column};
    }
    else {
      $table_name = $aliased_tables{$table_name} || $table_name;

      my $table   = $meta_schema->table($table_name)
                 || (firstval {($_->{db_name} || '') eq $table_name}
                              ($meta_source, $meta_source->ancestors))
                 || (firstval {uc($_->{db_name} || '') eq uc($table_name)}
                              ($meta_source, $meta_source->ancestors))
        or croak "unknown table name: $table_name";

      $handlers{$alias} = $table->{column_handlers}->{$column};
    }
  }

  # handlers may be overridden from args{-column_types}
  if (my $col_types = $self->{args}{-column_types}) {
    while (my ($type_name, $columns) = each %$col_types) {
      $columns = [$columns] unless does $columns, 'ARRAY';
      my $type = $self->schema->metadm->type($type_name)
        or croak "no such column type: $type_name";
      $handlers{$_} = $type->{handlers} foreach @$columns;
    }
  }

  # just keep the "from_DB" handlers
  my $from_DB_handlers = {};
  while (my ($column, $col_handlers) = each %handlers) {
    my $from_DB_handler = $col_handlers->{from_DB} or next;
    $from_DB_handlers->{$column} = $from_DB_handler;
  }
  $self->{from_DB_handlers} = $from_DB_handlers;

  return $self;
}

sub _find_result_class {
  my $self         = shift;
  my $name         = ucfirst shift;
  my $schema       = $self->schema;
  my $schema_class = ref $schema || $schema;

  # try to find subclass $name within namespace of schema or ancestors
  foreach my $namespace (@{$schema->resultAs_classes}) {
    my $class = "${namespace}::ResultAs::${name}";

    # see if that class is already loaded (by checking for a 'get_result' method)
    my $is_loaded  = defined &{$class."::get_result"};

    # otherwise, try to load the module
    $is_loaded ||= try   {load $class; 1}
                   catch {die $_ if $_ !~ /^Can't locate(?! object method)/};

    return $class if $is_loaded; # true : class is found, exit loop
  }

  return; # false : class not found
}



1; # End of DBIx::DataModel::Statement

__END__

=head1 NAME

DBIx::DataModel::Statement - DBIx::DataModel statement objects

=head1 DESCRIPTION

The purpose of a I<statement> object is to retrieve rows from the
database and bless them as objects of appropriate classes.

Internally the statement builds and then encapsulates a C<DBI>
statement handle (sth).

The design principles for statements are described in the
L<DESIGN|DBIx::DataModel::Doc::Design/"STATEMENT OBJECTS"> section of
the manual (purpose, lifecycle, etc.).

=head1 METHODS

Methods for statements are described in the 
L<Reference manual|DBIx::DataModel::Doc::Reference/"STATEMENTS">.

=head1 PRIVATE METHOD NAMES

The following methods or functions are used
internally by this module and 
should be considered as reserved names, not to be
redefined in subclasses :

=over

=item _bless_from_DB

=item _compute_from_DB_handlers

=item _find_result_class

=back


