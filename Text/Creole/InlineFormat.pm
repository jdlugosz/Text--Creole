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
 
method do_format (Str $line)
 {
 ##experiment with parsing
 my $simples = qr{\*\*};  # extensible by user.  Same opening and closing.
 my $ps= qr{(?<prematch>.*?)
     (?:
       (?<link>
          (?: \[\[\s*(?<body>.*?)\s*\]\]   )  # explicit use of brackets
          | (?:  (?<body>(?:http|ftp)s?://\S+)   )   # bare (just a start)
       )(*:link)
     | ~ (?<body> (?&link)|.|\Z  ) (*:escape)
	 | // \s* (?<body>(?: (?&link)  | . )*?)  \s*  (?: //|\Z)(*:italic)  # special rules for //, TODO start no problem, skip any links in body.
	 |  (?<simple>$simples)\s*(?<body>.*?)\s*(?:\k<simple>|\Z)(*:simple)
	 | \\\\ (*:break)
     | \{{3} \s* (?<body>.*?) \s* \}{3} (*:nowiki)  # be sure to check for three braces before checking for two.
     | \{{2} \s* (?<link>[^|]*?) \s* (?:  \|  (?<alt>.*?)  \s* )?   \}{2} (*:image)
     | \<{3} \s* (?<body>.*?) \s* \>{3} (*:placeholder)  # be sure to check for 3 angles before checking for 2 (extension)
	 | \Z (*:nada)  # must be the last branch
	)
	}xs;
 my @results;
 while ($line =~ /$ps/g) {
    my %captures;
    while (my($key,$value)=each %+) { $captures{$key}=$value }
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
   (qw/br  a  img td th / );

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
