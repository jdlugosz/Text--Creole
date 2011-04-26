use 5.10.1;
use utf8;
use autodie;
package Text::Creole;
use Moose;
use namespace::autoclean;
use MooseX::Method::Signatures;

use Text::Creole::LineBlocker;
use Text::Creole::InlineFormat;

=head1 NAME

Text::Creole - Parse Wiki Creole input and produce XHTML.

=cut


has line_blocker => (
   is => 'ro',
   default => sub { Text::Creole::LineBlocker->new; },
   handles => [qw( input_some input_all)],
   );

method build_inline_formatter
 { 
 return Text::Creole::InlineFormat->new(
      tag_formatter => $_[0],
      tag_data => $_[0]->tag_data,
      );  
 }

has inline_formatter => (
   is => 'ro',
   lazy => 1,
   builder => 'build_inline_formatter',
   );

our %default_tag_data=
   map { $_ => [ $_ ] } 
   (qw/ a  br  h1  h2  h3  h4  h5  h6  h7  h8  h9  hr  img  li  p  pre  td  th  tr / );

has tag_data => (
   is => 'rw',
   traits => ['Hash'],
   isa => 'HashRef',
   default => sub { \%default_tag_data },
   handles => {
      get_tag_data => 'get'
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

method output()
 {
 return map { 
    my $item= $_;
    $self->block_format($$item[0], $self->inline_formatter->format(@$item)) 
    }  ($self->line_blocker->output);
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

method open_list_containers (Str $type)
 {
 warn "open list containers for $type\n"; ###############
 my @lines;
 my @opens= $self->list_tag_types ($type);
 foreach my $tag (@opens) {
    push @lines, qq(<$tag>);  # for now.
    # todo: indenting
    }
 return @lines;
 }

method close_list_containers (Str $type)
 {
 warn "close list containers for $type\n"; ###############
 my @lines;
 my @opens= $self->list_tag_types ($type);
 foreach my $tag (@opens) {
    push @lines, qq(</$tag>);  # for now.
    # todo: indenting
    }
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
 given ("$state$incoming") {
    when ('TT' || 'oo') {  }  # nothing to do
    when ('LL') {  
       warn "In LL case\n";
       # >> deal with changing list levels
       $type= 'li';
       }
    when ('LT') {  
       warn "In LT case\n";
       $self->_block_state('T');
       }
    when ('Lo') {   # closing a list
       warn "In Lo case\n";
       push @results, $self->close_list_containers ($self->_list_state);
       $self->_block_state('o');
       }
    when ('TL') {  
       warn "In TL case\n";
       $self->_block_state('o');
       }
    when ('To') {  
       warn "In To case\n";
       $self->_block_state('o');
       }
    when ('oL') {   # opening a list
       push @results, $self->open_list_containers ($type);
       $self->_list_state ($type);
       $type= 'li';
       $self->_block_state('L');
       }
    when ('oT') {  }
    }
 # TODO: handle indenting (but not PRE)
 push @results, $self->format_tag ($self->get_tag_data($type), $text);
 return @results;
 }
 
=item format_tag

This formats a single tag, using the supplied data.  The normal meaning for generating xml is that the array contains the tag name and optional class name.  To repurpose this and format things in a totally different way, you can repurpose the meaning of the configured data and add more values to the array.

=cut

method format_tag (ArrayRef $data,  $body, Str $extra?)
 {
 my ($tag, $class)= @$data;
 my $classinfo=  defined $class ? qq( class="$class") : '';
 if ($tag eq 'img') {
    # this one is different!
    return qq(<$tag$classinfo src="$body" alt="$extra" />);
    }
 my $more= '';
 if (defined $extra) {
    die "Don't know how to format <$tag> with \$extra " unless $tag eq 'a';
	$more= qq( href="$extra");
    }
 if (!defined($body) || length($body)==0) {
    return "<$tag$classinfo />";
    }
 return "<$tag$classinfo$more>$body</$tag>";
 }


method escape (Str $line)
 {
 $line =~ s/&/&amp;/g;
 $line =~ s/</&lt;/g;
 return $line;
 }


 __PACKAGE__->meta->make_immutable;
