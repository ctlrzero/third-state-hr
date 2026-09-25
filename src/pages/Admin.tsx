import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { PageHeader, TabPanel, Tabs } from '../components/ui'
import { EntitiesTab } from './admin/EntitiesTab'
import { UsersTab } from './admin/UsersTab'
import { PoliciesTab } from './admin/PoliciesTab'
import { ImportTab } from './admin/ImportTab'

type TabKey = 'entities' | 'users' | 'policies' | 'import'
const TAB_KEYS: TabKey[] = ['entities', 'users', 'policies', 'import']

// Owner + Entity Admin only (enforced by the route gate in App.tsx and by
// every RPC). Entity Admins see entities read-only and can't grant Owner.
export default function Admin() {
  const { profile, activeEntityId, entities } = useAuth()
  const [params, setParams] = useSearchParams()
  const initial = (params.get('tab') as TabKey) ?? 'entities'
  const [tab, setTabState] = useState<TabKey>(TAB_KEYS.includes(initial) ? initial : 'entities')
  const isOwner = profile?.role === 'owner'
  const entityName = entities.find((e) => e.id === activeEntityId)?.name ?? 'this entity'

  function setTab(k: TabKey) {
    setTabState(k)
    setParams({ tab: k }, { replace: true })
  }

  return (
    <div className="space-y-5">
      <PageHeader title="Admin" description="Entities, branches, user access, policies and imports." />
      <Tabs<TabKey>
        label="Admin sections"
        active={tab}
        onChange={setTab}
        tabs={[
          { key: 'entities', label: 'Entities & branches' },
          { key: 'users', label: 'Users & access' },
          { key: 'policies', label: 'Policies' },
          { key: 'import', label: 'Bulk import' },
        ]}
      />
      <TabPanel id={tab}>
        {tab === 'entities' && <EntitiesTab isOwner={isOwner} />}
        {tab === 'users' && <UsersTab isOwner={isOwner} activeEntityId={activeEntityId} />}
        {tab === 'policies' && <PoliciesTab isOwner={isOwner} activeEntityId={activeEntityId} />}
        {tab === 'import' && <ImportTab activeEntityId={activeEntityId} entityName={entityName} />}
      </TabPanel>
    </div>
  )
}
