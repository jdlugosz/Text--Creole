use 5.10.1;
use utf8;
use autodie;
package Text::Creole;
use Moose;
use namespace::autoclean;
use MooseX::Method::Signatures;
use MooseX::Types::Moose qw/HashRef ArrayRef RegexpRef CodeRef/;

use Text::Creole::LineBlocker;
use Text::Creole::InlineFormat;

=head1 NAME

Text::Creole - Parse Wiki Creole input and produce XHTML.

=cut

method build_line_blocker
 {
 return Text::Creole::LineBlocker->new (
    parse_option => $self->parse_option
    );
 }

has line_blocker => (
   is => 'ro',
   lazy => 1,
   builder => 'build_line_blocker',
   handles => [qw( input_some input_all)],
   );

method build_inline_formatter
 { 
 return Text::Creole::InlineFormat->new(
      tag_formatter => $self,
      config_keeper => $self,
      tag_data => $self->tag_data,
      parse_option => $self->parse_option
      );
 }

has inline_formatter => (
   is => 'ro',
   lazy => 1,
   builder => 'build_inline_formatter',
   handles => [qw/simple_format_tags /],
   );

our %default_tag_data=
   map { $_ => [ $_ ] } 
   (qw/ a  br  h1  h2  h3  h4  h5  h6  hr  img  li  p  pre  td  th  tr / );

has tag_data => (
   is => 'rw',
   traits => ['Hash'],
   isa => HashRef,
   default => sub { \%default_tag_data },
   handles => {
      get_tag_data => 'get'
	  }, 
   );
   
has link_prefixes => (
   is => 'rw',
   isa => ArrayRef,
   default => sub { [ qw/http https ftp ftps/ ] },
   );
   
has placeholder_callback => (
   is => 'rw',
   isa => CodeRef,
   );

has link_mapper => (
   is => 'rw',
   isa => CodeRef,
   default => sub { \&default_link_mapper },
   );
   
has image_mapper => (
   is => 'rw',
   isa => CodeRef,
   );

my %default_parse_options= (
   'entity-passthrough-PRE' => 1,
   blended_links => 1,
   );

has parse_option => (
   is => 'rw',
   isa => 'HashRef',
   traits => ['Hash'],
   default => sub { \%default_parse_options },
   handles => {
      get_parse_option => 'get'
	  },
   );

has _block_state => (
   # used to keep track of opening/closing tags around the blocks actually present (ul, ol, table)
   is => 'rw',
   isa => 'Str',
   init_arg => undef,
   default => 'o',
   );

has _list_state => (
   # used to keep track of currently open list level
   is => 'rw',
   isa => 'Str',
   init_arg => undef,
   );

   
method BUILD ($args)
 {
 if ($args->{extended_simples}) {
    my $defs= $self->simple_format_tags;
    $defs->{'##'} = ['tt'];   # monospace
    $defs->{'^^'} = ['sup'];  # superscript
    $defs->{',,'} = ['sub'];  # subscript
    $defs->{'__'} = ['span', 'underlined']; # underlined
    }
 }
   
   
method output()
 {
 return map { 
    my $item= $_;
    $self->block_format($$item[0], $self->inline_formatter->format(@$item)) 
    }  ($self->line_blocker->output);
 }


method open_table_container
 {
 return "<table>";  # for now
 }

method close_table_container
 {
 return "</table>";  # for now
 }
 
 
 
method list_tag_types (Str $spec)
 {
 my @tags;
 foreach (split (//, $spec)) {
    when ('L') { next }  # skip optional leading L in specification.
    when ('*')  { push @tags, 'ul' }
    when ('#')  { push @tags, 'ol' }
    }
 return @tags;
 } 

method open_list_containers (Str $type, Bool $first)
 {
 my @lines;
 my @opens= $self->list_tag_types ($type);
 foreach my $tag (@opens) {
    if ($first) {
       push @lines, qq(<$tag>);  # for now.
       undef($first);
       }
    else {
       push @lines, qq(<li class="nestlist"><$tag>);  # for now.
       }
    # todo: indenting
    }
 return @lines;
 }

method close_list_containers (Str $type, Bool $last)
 {
 my @lines;
 my @opens= $self->list_tag_types ($type);
 my $lasttag;
 $lasttag= pop @opens  if $last;  # treat the final one differently
 foreach my $tag (reverse @opens) {
    push @lines, qq(</$tag></li>);  # for now.
    # todo: indenting
    }
 if ($lasttag) {
    push @lines, qq(</$lasttag>);  # for now.
    }
 return @lines;
 }

method change_list_levels (Str $type)
 {
 my $old_levels= $self->_list_state;
 $self->_list_state($type);
 ($type ^ $old_levels) =~ /^(\0+)/;
 my $prefix_len= length($1);
 substr($type, 0, $prefix_len) = '';
 substr($old_levels, 0, $prefix_len) = '';
 my $bottomed_out= $prefix_len==0;
 my @lines;
 push @lines, $self->close_list_containers ($old_levels, $bottomed_out);
 push @lines, $self->open_list_containers ($type, $bottomed_out);
 return @lines;
 }

 
method block_format (Str $type, Str $text)
 {
 my @results;
 my $state= $self->_block_state;  # L, T, or o.
 my $incoming;
 given ($type) {
    when (/^L/) { $incoming= 'L' }
    when ('tr') { $incoming= 'T' }
    default { $incoming= 'o' }
    }
 if ($state eq $incoming) {
    if ($state eq 'L') {
       push @results, $self->change_list_levels($type)   if $self->_list_state ne $type;
       $type= 'li';    
       }
    # otherwise, no change to current situations.
    }
 else {
    given ($state) {   # what I'm exiting
       when ('L') {  push @results, $self->close_list_containers ($self->_list_state, 1); }
       when ('T') {  push @results, $self->close_table_container; } 
       }
    given ($incoming) {   # what I'm entering
       when ('L') { 
          push @results, $self->open_list_containers ($type, 1);
          $self->_list_state ($type);
          $type= 'li';
          $self->_block_state('L');
          }
       when ('T') {
          push @results, $self->open_table_container;
          $self->_block_state('T');
          }
       }
    $self->_block_state($incoming);
    }
 # TODO: handle indenting (but not PRE)
 push @results, $self->format_tag ($self->get_tag_data($type), $text)   unless $type eq 'B';
 return @results;
 }
 
=item format_tag

This formats a single tag, using the supplied data.  The normal meaning for generating xml is that the array contains the tag name and optional class name.  To repurpose this and format things in a totally different way, you can repurpose the meaning of the configured data and add more values to the array.

=cut

method format_tag (ArrayRef $data,  $body, Str $extra?)
 {
 if ($$data[0] eq 'img') {
    # this one is different!
    my $class= $$data[1];
    my $classinfo=  defined $class ? qq( class="$class") : '';
    return qq(<img$classinfo src="$body" alt="$extra" />);
    }
 my $singular= !defined($body) || length($body)==0;
 my ($open,$close)= $self->format_tag_wrapper ($data, $extra, $singular);
 return $open  unless defined $close;
 return "$open$body$close";
 }


method format_tag_wrapper (ArrayRef $data,  Maybe[Str] $extra?, Bool $singular?)
 {
 my ($tag, $class)= @$data;
 my $classinfo=  defined $class ? qq( class="$class") : '';
 my $more= '';
 if (defined $extra) {
    die "Don't know how to format <$tag> with \$extra " unless $tag eq 'a';
	$more= qq( href="$extra");
    }
 return "<$tag$classinfo />" if $singular;
 return ("<$tag$classinfo$more>", "</$tag>");
 } 
 
=item escape

This is called to sanitize text of any special xml characters.  It is called for spans of plain text, and will not include the Creole formatting directives or any generated xhtml code.  If you repurpose this module to output something other than xhtml, you would need to change this.

=cut

method escape (Str $line, Str $type?)
 {
 my $entity_passthrough= 1;  #normally on.
 if (defined $type) {
    $entity_passthrough= $self->get_parse_option('entity-passthrough-PRE')   if ($type eq 'pre');
    }
 if ($entity_passthrough) {
    $line =~ s/
       &   #any ampersand...
       (?!  # that's NOT followed by stuff that would make it an Entity reference
          (?:  # various ways to form the guts of the Entity
             [a-zA-Z]+\d*  # some entity names end with digits, but never have them elsewhere.
             | \# (?:  # A numeric entity code
                \d+ |  (?:x|X) [[:xdigit:]]+
                )
          )
        ;  # and a trailing semicolon.
       )/&amp;/gx;
    }
 else {
    $line =~ s/&/&amp;/g;  # escape out ALL uses of '&'.
    }
 $line =~ s/</&lt;/g;
 return $line;
 }

method filter (Str $text)
 {
 # smart quotes
 $text =~ s/^"(?=\s)/”/;  # quote at beginning of sequence is closing (only) if it is followed by whitespace.
 $text =~ s/(?:[\s(]|\A)\K"/“/g;  # quote following space or '(' is opening
 $text =~ s/"/”/g;  # all others are closing
 # ...
 return $text;
 }
 
sub default_link_mapper
 {
 my ($linkref, $text)= @_;
 # this sanitizes any characters that cannot occur in a URI.  Reserved chars are expected to be used correctly, and not touched.
 my $re= qr/[^-_.~A-Za-z0-9!*'();:@&=+\$,\/?#\[\]]/;
 use bytes;
 $linkref =~ s/($re)/sprintf("%%%02X",ord($1))/ge;
 return ($linkref, $text);
 }
 

 __PACKAGE__->meta->make_immutable;
