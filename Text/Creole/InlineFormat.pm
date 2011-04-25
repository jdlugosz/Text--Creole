use 5.10.1;
use utf8;
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
 return $self->format_table_row($line)  if $type eq 'table-row';
 return $self->do_format ($line);
 }
 
method do_format (Str $line)
 {
 ##experiment with parsing
 my $simples = qr{\*\*};  # extensible by user.  Same opening and closing.
 my $ps= qr{(?<prematch>.*?)
    (?:
	  (?:(?<!http:)//) \s* (?<body>.*?)\s*(?: (?:(?<!http:)//)|\Z)(*:italic)  # special rules for //, TODO start no problem, skip any links in body.
	 |  (?<simple>$simples)\s*(?<body>.*?)\s*(?:\k<simple>|\Z)(*:simple)
	 | \\\\ (*:break)
	 | \[\[\s*(?<body>.*?)\s*\]\](*:link)
	 | \Z (*:nada)  # must be the last branch
	)
	}xs;
 my @results;
 while ($line =~ /$ps/g) {
	# careful not to trash my capture variables!  So no using regex at all until I determined what I need and saved it.
    my $prematch= $+{prematch};
	my $s;
	my $body= $+{body};
	if ($REGMARK eq 'simple') {
	   my $style= $+{simple};
	   $s= $self->simple_format ($style, $body);
	   }
	elsif ($REGMARK eq 'italic') {
	   $s= $self->simple_format ('//', $body);
	   }
	elsif ($REGMARK eq 'break') {
	   $s= $self->format_tag ($self->get_tag_data('br'), undef);
	   }
	elsif ($REGMARK eq 'link') {
	   $s= $self->process_link_body ($body);
	   }
	# other cases...
	push @results, $self->escape($prematch)  unless length($prematch)==0;
	push @results, $s  if defined $s;
	}
 return join ('', @results);
 }

 
method process_link_body (Str $body)
 {
 my ($link,$text)= split (/\s*\|\s*/, $body, 2);
 $text //= $link;
 my $href= $link;   # TODO: map strings to full URL
 return $self->format_tag ($self->get_tag_data('a'), $text, $href);
 }

=item simple_format

This handles formatting of the so-called "simple" format codes.  These have the same sequence opening and closing, and the built-in ones are bold and italics.  These are extensible by the caller, so this looks up the tag in a configuration table.

=cut

my %simple_format_tag= (
   # for now.  Will be extendable and customizable.
   '**' => ['strong'],  # tag,class pairs with class optional.  Same general format as will be used to configure the tags.
   '//' => ['em']
   );

method simple_format (Str $style, Str $body)
 {
 $body= $self->do_format($body);
 return $self->format_tag ($simple_format_tag{$style}, $body);
 }

=item format_tag

This formats a single tag, using the supplied data.  The normal meaning for generating xml is that the array contains the tag name and optional class name.  To repurpose this and format things in a totally different way, you can repurpose the meaning of the configured data and add more values to the array.

This should be hoised out of this class.  Here for now.

=cut

method format_tag (ArrayRef $data,  $body, Str $extra?)
 {
 my ($tag, $class)= @$data;
 my $classinfo=  defined $class ? qq( class="$class") : '';
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

method format_table_row (Str $line)
 {
 ## stub so far
 return "TABLEFMT($line)";
 }

method formatting_enabled (Str $type)
 {
 given ($type) {
    when (/^h/) {
	   return 0;   # will make configurable.
	   }
	when ('Pre') { return 0; }
    default { return 1; }
    }
 }

method escape (Str $line)
 {
 $line =~ s/&/&amp;/g;
 $line =~ s/</&lt;/g;
 return $line;
 }

our %default_tag_data=
   map { $_ => [ $_ ] } 
   (qw/br  a/ );

has  tag_data => (
   is => 'bare',
   traits => ['Hash'],
   isa => 'HashRef',
   handles => {
      get_tag_data => 'get'
	  }, 
   default => sub { \%default_tag_data },
   );

__PACKAGE__->meta->make_immutable;
