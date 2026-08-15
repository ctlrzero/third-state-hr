import { EmptyState } from '../components/EmptyState'

// Placeholder for modules outside this pass's scope (sign-in, dashboard,
// employee directory). Kept as a real route + real nav entry rather than a
// dead link, per the design spec's rule against implying an action is
// possible when it isn't.
export default function ComingSoon({ title }: { title: string }) {
  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-semibold text-ink md:text-[28px]">{title}</h1>
      <EmptyState
        title="This module is being built next"
        description="Sign-in, the operations dashboard and the employee directory shipped first. This screen wires up to the same live Supabase tables and RLS policies once it's next in line."
      />
    </div>
  )
}
