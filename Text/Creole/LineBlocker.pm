use 5.10.1;
use utf8;
package Text::Creole::LineBlocker;
use Moose;
use namespace::autoclean;
use MooseX::Method::Signatures;

=head1 NAME

Text::Creole::LineBlocker - a component of Text::Creole

=item input_some and input_all

Pass lines of text to this object by calling C<input_some (@lines)>.  You can call it any number of times, passing more lines to process.  The last gulp of input should use C<input_all (@lines)> instead, which indicates that the file has ended.  You can then continue to make more calls to these functions, such as if processing multiple input files that will be concatenated together such that a paragraph does not span a file boundary.

The lines will be chomped, so a trailing newline is optional.  The input is assumed to be lines regardless of the presence of a newline.  Note that this function doesn't like lines ending in \r\n, and that should be normalized earlier (e.g. when reading the lines via an input layer).

=cut
 
method input_some (Str @lines)
 {
 foreach my $line (@lines) {
    my $linenum= $self->input_line_number;
	++$linenum;
	$self->input_line_number ($linenum);
    chomp $line;
    my $ptype= $self->classify_line ($line);
	$ptype= $self->classify_in_context ($ptype, $line);
	my $keepgoing= $self->relate_to_current ($ptype, $line);
	next unless $keepgoing;
    my $f= "process_line_" . $ptype;
	$self->$f ($line);
    }
 }
 
method input_all (Str @lines)
 {
 $self->input_some (@lines);
 # >>then do something else to seal it off
 }


=item output

Calling C<<@results= $lineblocker->output>> will return any pending results as a list.  You can call C<output> after any amount of input has been given, and it will return what is complete up to that point and give up those values so they will no longer be taking up memory.  The next call to C<output>, presumably after more input has been presented, will return additional items.

If called after C<input_some>, as opposed to C<input_all>, there may be some work in progress still under consideration, so the output will not contain all of the input.

The results are a list of items, each of which contains C<[ type, content ]>.  The content is the text of the block, which will be (possibly) multiple lines of input joined together, with the non-content identifying prefix and (if applicable) suffix removed.  The C<type> will describe the type of block.

=cut
 
method output()
 {
 my $results= $self->_results;
 $self->clear_results;
 return @$results;
 }

 
=item classify_line

This is used to make a preliminary determination as to what a line is.  It is preliminary because it doesn't consider if it's in the middle of something; it looks at the line as if it were the first/only line.  It also may be rejected as a block type later if it doesn't fit all the rules in force.
You could override this to add more block primitives or adjust the recognition rules.

=cut
 
method classify_line (Str $line)
 {
 given ($line) {
    when (/^\s*=+/) {
	   # Spec doesn't state that space following the string of ='s is necessary, but all examples have them.
	   # But the wikicreole1.txt file has examples where spaces following are not present.
	   return 'h';
	   }
	when (/^\s*[*#]+/) {
	   return 'L';  # some kind of List: Ordered, Unordered, mixture
	   }
	when (/^\s*:/ && $self->get_parse_option(':')) {
	   return ':';  # Indented paragraph
	   }
	when (/^\s*-{4}\s*$/) {
	   return 'R';  # Horizontal Rule
	   }
	when (/^\s*\|/) {
	   return 'T';  # Table row starts with a pipe.
	   }
	when (/^\{{3}$/) {
	   return 'startPre';  # only thing on a line, no whitespace.
	   }
	when (/^\}{3}$/) {
	   return 'endPre';  # only thing on a line, no whitespace.
	   }
	when (/^\s*$/) {
		return 'B';  # blank line
		}
    default {
	   return 'p';  # default is plain paragraph, if nothing else matches
       }
    }
 }

 
=item classify_in_context

This is called to validate that the provisional line-block type is allowed here.  It may be rejected and treated as plain p if that thing is not allowed based on the current situation.

=cut

method classify_allowed_list (Str $ptype, Str $line)
 {
 # If current line seems to be a List item, it has to match the current list, reduce it, or extend it by only one level.
 # (This could also prevent you from nesting too deeply.  Currently there is no limit imposed.)
 if ($ptype eq 'L') { 
    my $prev= $self->_current_state // $self->_prev_type;
	$line =~ /^\s*([*#]+:?)/;
    my $prefix= "L$1";
	if (!defined($prev) || $prev !~ /^L/) {
	   # if not extending an existing list, must be starting one
	   return length($prefix) == 2 ? $ptype : 'p';
	   }
	my $increase= length($prefix) - length($prev);
	given ($increase) {
	   when ($_ >1) { return 'p'; }  # reject that.  make it a plain paragraph.
	   when (1) {
	      chop $prefix;
	      return 'p' unless $prev eq $prefix;
	      }
	   when (0) {  return 'p' unless $prev eq $prefix; }
       when ($_ < 0) {
	      return 'p' unless $prefix eq substr($prev, 0, $increase);
	      }
	   }
    }
 return $ptype;   # unchanged.
 }

method classify_in_context (Str $ptype, Str $line)
 {
 my $state= $self->_current_state;
 given ($state) {
    when (!defined) { }  # just prevent warnings when it never matches the regex anyway.
	when (/^pre/) {
	   return 'cont' unless $ptype eq 'endPre';
       return $ptype;
	   }
    when (/^(p|L)/) {
	   # ❝One or more blank lines end paragraphs. A list, table or nowiki block end paragraphs too.❞
	   # ❝A list item ends at the line which begins with a * or # character (next item or sublist), blank line, heading, table, or nowiki block❞
	   return 'cont' unless $ptype ~~ [qw/B L T : startPre/];
	   }
    }
 $ptype= 'p'  if $ptype eq 'endPre';  # if PRE is not open, closing doesn't have any special meaning.
 $ptype= $self->classify_allowed_list ($ptype, $line)  if $ptype eq 'L';
 return $ptype;
 }


=item relate_to_current ($ptype, $line)

This is called to deal with the current block being built.  It may add the $line to it.  It may complete the block.
If the line should still be processed, return True.

=cut

method relate_to_current (Str $ptype, Str $line)
 {
 my $state= $self->_current_state;
 return 1 unless defined $state;
 return 1  unless $state =~ /^(p|pre|L)/;  # only these get a multi-line block
 my $current_type= $1;
 # I might have suffexes to the primtive types, so match the first part of the string with the proffered extension.
 if ($ptype eq 'cont') {
	if ($current_type eq 'pre' && $line =~ /^\s+\}{3}\s*$/) {
       # check for non-ending }}} line.
	   substr($line,0,1) = '';  # remove the first character
	   }
    $self->add_to_current_para ($line);
	return undef;  # tell caller I took it.
    }
 if ($ptype eq 'endPre') {
    $self->add_to_current_para ('');  #end a PRE block with a line break.
    }
 $self->complete_current_para;
 if ($ptype ~~ [qw/endPre/]) {
	return undef;
    }
 return 1;
 }
 
 
method complete_current_para
 {
 my $state= $self->_current_state;
 my $lines= $self->_current_para;
 my $joiner= "\n";  # make configurable for plain paragraphs.
 $self->clear_current_para;
 $self->clear_current_state;
 my $text= join ($joiner, @$lines);
 $self->_add_result($state, $text);
 }

method process_line_p ($line)
 {
 $self->add_to_current_para ($line);
 $self->_current_state ('p');
 }

method process_line_L ($line)
 {
 # some kind of List
 my ($prefix, $content) = $line =~ /^\s*([*#]+:?)\s*(.*\S)?(?:(?<=\S)\s*)?$/;
 warn "Current line is ($line)\n"  if !defined($prefix);
 $prefix= "L$prefix";
 $self->add_to_current_para ($content);
 $self->_current_state ($prefix);
 }

method process_line_startPre ($line)
 {
 $self->_current_state ('pre');
 }
 
method process_line_T ($line)
 {
 $self->_add_result('tr', $line);
 }
 
method process_line_B ($line)
 {
 $self->_add_result('B', '');
 $self->clear_current_state();
 # Acts as a separator so current "thing" is ended.
 # in particular, a blank line terminates a list block.  So next phase might need to know it was here.
 }
 
method process_line_h ($line)
 {   # header
 my ($prefix, $content) = $line =~ /^\s*(=+)\s*(*PRUNE)(.*?)\s*=*\s*$/;
 my $type= 'h' . length($prefix);
 $self->_add_result($type, $content);
 }

method process_line_R ($line) 
 {  # horizontal rule
 $self->_add_result('hr', ''); 
 }


method _add_result (Str $type, Str $value)
 {
 $self->_prev_type ($type);
 $self->_add_result_list ([$type, $value]);
 }
 
 
has _results => (
	is => 'ro',
	clearer => 'clear_results',
	init_arg => undef,
	traits  => ['Array'],
	isa     => 'ArrayRef[ArrayRef]',
	default => sub { [] },
	handles => {
		_add_result_list => 'push',
		},
	);

# The current paragraph (or other multi-line block, of whatever type) stores the existing lines while seeing if more lines will be added.  I presume that noting the lines in a list and then joining them together will be more efficient than catentating as it goes, since join knows all the input before allocating the result string.  It also lets me put off chomping them until the final block string is built.
has _current_para => (
	is => 'ro',
	clearer => 'clear_current_para',
	init_arg => undef,
	traits => ['Array'],
	isa => 'ArrayRef[Str]',
	default => sub { [] },
	handles => {
		add_to_current_para => 'push',
		},
	);

# This keeps track of what the _current_para is building, or whether I'm in a list of some level.
has _current_state => (
   is => 'rw',
   init_arg => undef,
   isa => 'Str',
   clearer => 'clear_current_state',
   );
	

# Options understood here:
# ':' Bool - allows leading : to make an indented paragraph (or unnumbered list item)
has parse_option => (
   is => 'bare',
   traits => ['Hash'],
   isa => 'HashRef',
   handles => {
      get_parse_option => 'get'
	  },
   );
	

has input_line_number => (
   is => 'rw',
   default => 0,
   isa => 'Int',
   );


has _prev_type => (
   is => 'rw',
   init_arg => undef,
   isa => 'Str',
   );
 
__PACKAGE__->meta->make_immutable;
 
