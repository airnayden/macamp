import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { baseOptions } from '@/lib/layout.shared';
import { SidebarBanner, SidebarFooter } from '@/components/brand';

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...baseOptions()}
      sidebar={{ banner: <SidebarBanner />, footer: <SidebarFooter /> }}
    >
      {children}
    </DocsLayout>
  );
}
