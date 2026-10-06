import { DocumentTitle, useK8sWatchResource } from '@openshift-console/dynamic-plugin-sdk';
import { PageSection, Title, Label, Spinner, EmptyState, EmptyStateBody } from '@patternfly/react-core';
import { Table, Thead, Tbody, Tr, Th, Td } from '@patternfly/react-table';
import {
  CheckCircleIcon,
  ExclamationCircleIcon,
  ExternalLinkAltIcon,
} from '@patternfly/react-icons';
import type { FC } from 'react';

const NS = 'opencode-users';
const APP_LABEL = 'opencode-agent';

type K8sObj = {
  metadata?: { name?: string; labels?: Record<string, string> };
  status?: { readyReplicas?: number; replicas?: number };
  spec?: { host?: string };
};

const AgentsPage: FC = () => {
  const [deps, depsLoaded, depsErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { version: 'v1', kind: 'Deployment' },
    namespace: NS,
    isList: true,
  });
  const [pods, podsLoaded] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { version: 'v1', kind: 'Pod' },
    namespace: NS,
    isList: true,
  });
  const [routes, routesLoaded] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'route.openshift.io', version: 'v1', kind: 'Route' },
    namespace: NS,
    isList: true,
  });
  const [secrets, secretsLoaded] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { version: 'v1', kind: 'Secret' },
    namespace: NS,
    isList: true,
  });

  const agents = (depsLoaded ? (deps ?? []) : []).filter(
    (d) => d.metadata?.labels?.app === APP_LABEL,
  );

  const podStatus = (user: string) => {
    if (!podsLoaded) return null;
    const mine = (pods ?? []).filter((p) => p.metadata?.labels?.user === user);
    if (mine.length === 0) return null;
    const ready = mine.filter((p) =>
      (p.status as { conditions?: { type: string; status: string }[] } | undefined)?.conditions?.some(
        (c) => c.type === 'Ready' && c.status === 'True',
      ),
    );
    return `${ready.length}/${mine.length} pods`;
  };

  const routeHost = (user: string) => {
    if (!routesLoaded) return null;
    const r = (routes ?? []).find((x) => x.metadata?.name === `opencode-${user}`);
    return (r?.spec as { host?: string } | undefined)?.host ?? null;
  };

  const hasKey = (user: string) => {
    if (!secretsLoaded) return null;
    return (secrets ?? []).some((s) => s.metadata?.name === `opencode-maas-key-${user}`);
  };

  return (
    <>
      <DocumentTitle>OpenCode - Agentes</DocumentTitle>
      <PageSection>
        <Title headingLevel="h1">OpenCode - Agentes</Title>
        <p>
          Entornos de agentes OpenCode del proyecto <code>{NS}</code>. Cada agente sirve su web UI
          en su ruta y usa el MaaS del cluster con la API key de su usuario.
        </p>
      </PageSection>
      <PageSection>
        {depsErr ? (
          <EmptyState titleText="Error cargando agentes">
            <EmptyStateBody>{String(depsErr)}</EmptyStateBody>
          </EmptyState>
        ) : !depsLoaded ? (
          <Spinner size="lg" />
        ) : agents.length === 0 ? (
          <EmptyState titleText="Sin agentes">
            <EmptyStateBody>
              No hay deployments con label <code>app={APP_LABEL}</code> en {NS}. Crea agentes con{' '}
              <code>manifests/apply-opencode-users.sh</code>.
            </EmptyStateBody>
          </EmptyState>
        ) : (
          <Table aria-label="Agentes OpenCode">
            <Thead>
              <Tr>
                <Th>Agente</Th>
                <Th>Estado</Th>
                <Th>API key MaaS</Th>
                <Th>Web UI</Th>
                <Th>API</Th>
              </Tr>
            </Thead>
            <Tbody>
              {agents.map((d) => {
                const user = d.metadata?.labels?.user ?? d.metadata?.name ?? '';
                const status = podStatus(user);
                const host = routeHost(user);
                const key = hasKey(user);
                return (
                  <Tr key={d.metadata?.name}>
                    <Td>{user}</Td>
                    <Td>
                      {status === null ? (
                        <Spinner size="sm" />
                      ) : status.startsWith('0/') ? (
                        <Label color="red" icon={<ExclamationCircleIcon />}>
                          {status}
                        </Label>
                      ) : (
                        <Label color="green" icon={<CheckCircleIcon />}>
                          {status}
                        </Label>
                      )}
                    </Td>
                    <Td>
                      {key === null ? (
                        <Spinner size="sm" />
                      ) : key ? (
                        <Label color="green" icon={<CheckCircleIcon />}>
                          Configurada
                        </Label>
                      ) : (
                        <Label color="orange" icon={<ExclamationCircleIcon />}>
                          Sin key
                        </Label>
                      )}
                    </Td>
                    <Td>
                      {host ? (
                        <a href={`https://${host}`} target="_blank" rel="noreferrer">
                          {host} <ExternalLinkAltIcon />
                        </a>
                      ) : (
                        '-'
                      )}
                    </Td>
                    <Td>
                      {host ? (
                        <a href={`https://${host}/doc`} target="_blank" rel="noreferrer">
                          /doc <ExternalLinkAltIcon />
                        </a>
                      ) : (
                        '-'
                      )}
                    </Td>
                  </Tr>
                );
              })}
            </Tbody>
          </Table>
        )}
      </PageSection>
    </>
  );
};

export default AgentsPage;
