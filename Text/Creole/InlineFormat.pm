use 5.10.1;
use utf8;
use autodie;
package Text::Creole::InlineFormat;
use Moose;
use namespace::autoclean;
use MooseX::Method::Signatures;

our $REGMARK;

=head1 NAME

Text::Creole::InlineFormat - a component of Text::Creole

=item format

Expands inline formatting codes and escapes out any special characters for the output stream.

=cut

method format (Str $type, Str $line)
 {
 # some types ignore formatting codes.  This could be generalized to select some codes used for each type, but now it's all or nothing.
 return $self->escape ($line)  unless $self->formatting_enabled($type);
 return $self->format_table_row($line)  if $type eq 'tr';
 return $self->do_format ($line);
 }

sub REwrap($) { return '(?: ' . $_[0] . ' )' }

method _build_parser_spec
 {
 my $simples_string= join "|", map { $_ eq '//' ? () : quotemeta($_) }  (keys %{$self->simple_format_tags});
 my $simples = qr{$simples_string};  # extensible by user.  Same opening and closing.
 my $linkprefix_string= join "|", map { quotemeta($_) } @{$self->link_prefixes};
 my $linkprefix= qr{$linkprefix_string};
 my $link= qr{
       (?<link>
          (?: \[\[\s*(?<body>.*?)\s*\]\]   )  # explicit use of brackets
          | (?:  (?<body>$linkprefix://\S+)   )   # bare (just a start)
       )(*:link)
    }x;
 my $nowiki= REwrap q{
    \{{3} \s* (?<body>.*?) \s* \}{3} (*:nowiki)
    };
 my $image= qr{
    \{{2} \s* (?<link>[^|]*?) \s* (?:  \|  (?<alt>.*?)  \s* )?   \}{2} (*:image)
    }xs;
 my $placeholder= qr{
    \<{3} \s* (?<body>.*?) \s* \>{3} (*:placeholder)
    }xs;
 my $extensions= qr/(*FAIL)/;
 my $italic= REwrap q{// \s* (?<body>(?: (?&link)  | . )*?)  \s*  (?: (?: (?<!~)//) | \Z)(*:italic) };   # special rules for //, skip any links in body.
 my $simple= REwrap q{(?<simple>} . $simples . q{)\s*(?<body>.*?) \s* (?: (?: (?<!~)\k<simple>) | \Z)  (*:simple)};
 my $escape= REwrap q{~ (?<body> (?&link)|.|\Z  ) (*:escape)};
 my $ps_string= qq{(?<prematch>.*?)
     (?:
     $link
     #   tilde string will go HERE
     |  $escape
     |  $italic
	 |  $simple
	 | \\\\ (*:break)
     | $nowiki  # be sure to check for three braces before checking for two.
     | $image
     | $placeholder  # be sure to check for 3 angles before checking for 2 (extension)
     | $extensions
	 | \\Z (*:nada)  # must be the last branch
	)
	};
 my $ps= qr/$ps_string/xs;
 warn "$ps\n";
 return $ps;
 }

method do_format (Str $line)
 {
 my @results;
 my $ps= $self->_parser_spec;
 while ($line =~ /$ps/g) {
    my %captures= %+;
	my $regmark= $REGMARK;
    my $prematch= $captures{prematch};
	push @results, $self->escape($prematch)  unless length($prematch)==0;
    push @results, $self->grammar_branch ($regmark, \%captures);
    }
 return join ('', @results);
 }

=item grammar_branch

This is called after identifying a match from the inline formatting grammar.  Extend it to add processing for any new branches you add to the grammar.

It can return a list of strings that are concatenated by the caller.

=cut

## Or, maybe this should be a separate function for each branch?
method grammar_branch (Str $regmark, HashRef $captures)
 {
 my $body= $$captures{body};
 given ($regmark) {
    when ('simple') {
       my $style= $$captures{simple};
	   return $self->simple_format ($style, $body);
	   }
	when ('italic') {
	   return $self->simple_format ('//', $body);
	   }
	when ('break') {
	   return $self->format_tag ($self->get_tag_data('br'), undef);
	   }
	when ('link') {   # change this to parse out | in already, like with img.
	   return $self->process_link_body ($body);
	   }
	when ('nowiki') {
       return $self->escape($body);
       }
	when ('escape') {
       $body= "~$body"  if $body =~ /^\s*$/s;   # keep it if followed by blank or line-end
       return $self->escape($body);
       }
    when ('image') {
       return $self->process_image ($$captures{link}, $$captures{alt});
       }
    when ('placeholder') {
       return $self->process_placeholder ($body);
       }
	}
 }
 
 

=item process_placeholder
 
This method is called when the placeholder syntax is seen.  Override it to do something useful with placeholders.
 
=cut
 
method process_placeholder (Str $body)
 {
 return $self->format_tag ([ 'span', 'placeholder' ], $self->escape($body));
 }
 
 
method process_link_body (Str $body)
 {
 my ($link,$text)= split (/\s*\|\s*/, $body, 2);
 $text //= $link;
 my $href= $link;   # TODO: map strings to full URL
 return $self->format_tag ($self->get_tag_data('a'), $text, $href);
 }

method process_image (Str $link, $alt)
 {
 $alt //= 'image';
 my $href= $link;   # TODO: map strings to full URL
 return $self->format_tag ($self->get_tag_data('img'), $href, $alt); 
 }
 
 
 
=item simple_format

This handles formatting of the so-called "simple" format codes.  These have the same sequence opening and closing, and the built-in ones are bold and italics.  These are extensible by the caller, so this looks up the tag in a configuration table.

=cut


has simple_format_tags => (
   is => 'rw',
   isa => 'HashRef',
   default => sub { {
      '**' => ['strong'],  # tag,class pairs with class optional.
      '//' => ['em']
      }} ,
   );
   
method simple_format (Str $style, Str $body)
 {
 $body= $self->do_format($body);
 return $self->format_tag ($self->simple_format_tags->{$style}, $body);
 }


method format_table_row (Str $line)
 {
 my @cells= split (/\s*(?:\|\s*|\Z)/, $line);
 shift @cells;  #leading pipe always creates a leading empty value
 return join '', map {
    my $s= $_;
    my $tag= 'td';
    if ($s =~ /^=\s*(.*)$/) {
       $s= $1;
       $tag= 'th';
       }
    $self->format_tag ($self->get_tag_data($tag), $self->do_format($s));
    } @cells;
 }

method formatting_enabled (Str $type)
 {
 given ($type) {
    when (/^h/) {
	   return 0;   # will make configurable.
	   }
	when ('pre') { return 0; }
    default { return 1; }
    }
 }

has  tag_data => (
   is => 'bare',
   traits => ['Hash'],
   isa => 'HashRef',
   handles => {
      get_tag_data => 'get'
	  }, 
   required => 1,
   );

has tag_formatter => (
    is => 'bare',
    handles => [ qw( format_tag escape link_prefixes)],
    required => 1,
    weak_ref => 1,  # normally points back to parent Creole object
    );

has _parser_spec => (
   is => 'rw',
   isa => 'RegexpRef',
   init_arg => undef,
   builder => '_build_parser_spec',
   lazy => 1,
   );
   
__PACKAGE__->meta->make_immutable;
