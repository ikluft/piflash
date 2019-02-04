Name:           <% $zilla->name %>
Version:		<% (my $v = $zilla->version) =~ s/^v//; $v %>
Release:        1%{?dist}
Summary:        <% $zilla->abstract %>
License:        Apache Software License
BuildArch:      noarch
URL:            <% $zilla->license->url %>
Source:			<% $archive %>

BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildRequires:  perl-interpreter
BuildRequires:  perl >= 1:v5.18.0
BuildRequires:  perl(autodie)
BuildRequires:  perl(Carp)
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  perl(File::Basename)
BuildRequires:  perl(File::LibMagic)
BuildRequires:  perl(File::Slurp)
BuildRequires:  perl(Getopt::Long)
BuildRequires:  perl(IO::Handle)
BuildRequires:  perl(IO::Poll)
BuildRequires:  perl(Moose)
BuildRequires:  perl(POSIX)
BuildRequires:  perl(Test::More)
Requires:       perl(autodie)
Requires:       perl(Carp)
Requires:       perl(File::Basename)
Requires:       perl(File::LibMagic)
Requires:       perl(File::Slurp)
Requires:       perl(Getopt::Long)
Requires:       perl(IO::Handle)
Requires:       perl(IO::Poll)
Requires:       perl(POSIX)
Requires:       perl(Exception::Class)
Requires:       perl(Try::Tiny)
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))

%{?perl_default_filter}

%description
<% $zilla->abstract %>

%prep
%setup -q

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
[ -d %{perl_vendorlib} ] || mkdir -p %{perl_vendorlib}
[ -d %{_mandir} ] || mkdir -p %{_mandir}
make %{?_smp_mflags}

%install
[ "$RPM_BUILD_ROOT" != "/" ] &&	rm -rf $RPM_BUILD_ROOT
make pure_install DESTDIR=$RPM_BUILD_ROOT
find $RPM_BUILD_ROOT -type f \( -name .packlist -o -name perllocal.pod -o -name dist.ini \) -exec rm -f {} \;
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;
%{_fixperms} $RPM_BUILD_ROOT/*

%check
make test

%clean
[ "$RPM_BUILD_ROOT" != "/" ] &&	rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc Changes dist.ini LICENSE META.json README README.md
%{perl_vendorlib}/*
%{_mandir}/man3/*.3*
%{_mandir}/man1/*.1*
%{_bindir}/*

%changelog
