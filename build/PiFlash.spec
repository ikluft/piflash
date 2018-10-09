Name:           <% $zilla->name %>
Version:		<% (my $v = $zilla->version) =~ s/^v//; $v %>
Release:        1%{?dist}
Summary:        <% $zilla->abstract %>
License:        Apache Software License
BuildArch:      noarch
URL:            <% $zilla->license->url %>
Source:			<% $archive %>

BuildRoot:      %{_tmppath}/%{name}-%{version}-BUILD

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
BuildRequires:  perl(strict)
BuildRequires:  perl(Test::More)
BuildRequires:  perl(warnings)
Requires:       perl(autodie)
Requires:       perl(Carp)
Requires:       perl(File::Basename)
Requires:       perl(File::LibMagic)
Requires:       perl(File::Slurp)
Requires:       perl(Getopt::Long)
Requires:       perl(IO::Handle)
Requires:       perl(IO::Poll)
Requires:       perl(Moose)
Requires:       perl(POSIX)
Requires:       perl(strict)
Requires:       perl(warnings)
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))

%description
<% $zilla->abstract %>

%prep
%setup -q

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
[ -d %{perl_vendorlib} ] || mkdir -p %{perl_vendorlib}
[ -d %{_mandir} ] || mkdir -p %{_mandir}
make

%install
if [ "%{buildroot}" != "/" ] ; then
	rm -rf %{buildroot}
fi
make install DESTDIR=%{buildroot}
find %{buildroot} -type f -name .packlist -exec rm -f {} \;
find %{buildroot} -type f -name perllocal.pod -exec rm -f {} \;
find %{buildroot} -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

%check
make test

%clean
if [ "%{buildroot}" != "/" ] ; then
	rm -rf %{buildroot}
fi

%files
%defattr(-,root,root,-)
%doc Changes dist.ini LICENSE META.json README README.md
%{perl_vendorlib}/*
%{_mandir}/man3/*
%{_mandir}/man1/*
%{_bindir}/*
