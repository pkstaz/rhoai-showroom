import {
  DocumentTitle,
  useK8sWatchResource,
  k8sCreate,
  k8sGet,
  k8sDelete,
  k8sPatch,
} from '@openshift-console/dynamic-plugin-sdk';
import {
  PageSection,
  Title,
  Label,
  Spinner,
  EmptyState,
  EmptyStateBody,
  Button,
  Alert,
  Split,
  SplitItem,
} from '@patternfly/react-core';
import { Table, Thead, Tbody, Tr, Th, Td } from '@patternfly/react-table';
import {
  CheckCircleIcon,
  ExclamationCircleIcon,
  ExternalLinkAltIcon,
} from '@patternfly/react-icons';
import type { FC } from 'react';
import { useEffect, useState } from 'react';
import { BUNDLE_JSON, BUNDLE_CHART_VERSION, RBAC_JSON } from './bundle';

type K8sObj = Record<string, any>;

type Model = {
  abbr: string;
  kind: string;
  label: string;
  labelPlural: string;
  plural: string;
  apiVersion: string;
  apiGroup?: string;
  namespaced: boolean;
};

const models: Record<string, Model> = {
  NetworkPolicy: { abbr: 'np', kind: 'NetworkPolicy', label: 'NetworkPolicy', labelPlural: 'NetworkPolicies', plural: 'networkpolicies', apiVersion: 'v1', apiGroup: 'networking.k8s.io', namespaced: true },
  ServiceAccount: { abbr: 'sa', kind: 'ServiceAccount', label: 'ServiceAccount', labelPlural: 'ServiceAccounts', plural: 'serviceaccounts', apiVersion: 'v1', namespaced: true },
  Secret: { abbr: 's', kind: 'Secret', label: 'Secret', labelPlural: 'Secrets', plural: 'secrets', apiVersion: 'v1', namespaced: true },
  ConfigMap: { abbr: 'cm', kind: 'ConfigMap', label: 'ConfigMap', labelPlural: 'ConfigMaps', plural: 'configmaps', apiVersion: 'v1', namespaced: true },
  Role: { abbr: 'r', kind: 'Role', label: 'Role', labelPlural: 'Roles', plural: 'roles', apiVersion: 'v1', apiGroup: 'rbac.authorization.k8s.io', namespaced: true },
  RoleBinding: { abbr: 'rb', kind: 'RoleBinding', label: 'RoleBinding', labelPlural: 'RoleBindings', plural: 'rolebindings', apiVersion: 'v1', apiGroup: 'rbac.authorization.k8s.io', namespaced: true },
  Service: { abbr: 'svc', kind: 'Service', label: 'Service', labelPlural: 'Services', plural: 'services', apiVersion: 'v1', namespaced: true },
  StatefulSet: { abbr: 'sts', kind: 'StatefulSet', label: 'StatefulSet', labelPlural: 'StatefulSets', plural: 'statefulsets', apiVersion: 'v1', apiGroup: 'apps', namespaced: true },
  Job: { abbr: 'j', kind: 'Job', label: 'Job', labelPlural: 'Jobs', plural: 'jobs', apiVersion: 'v1', apiGroup: 'batch', namespaced: true },
  Route: { abbr: 'rt', kind: 'Route', label: 'Route', labelPlural: 'Routes', plural: 'routes', apiVersion: 'v1', apiGroup: 'route.openshift.io', namespaced: true },
  Pod: { abbr: 'p', kind: 'Pod', label: 'Pod', labelPlural: 'Pods', plural: 'pods', apiVersion: 'v1', namespaced: true },
  Namespace: { abbr: 'ns', kind: 'Namespace', label: 'Namespace', labelPlural: 'Namespaces', plural: 'namespaces', apiVersion: 'v1', namespaced: false },
  ClusterRole: { abbr: 'cr', kind: 'ClusterRole', label: 'ClusterRole', labelPlural: 'ClusterRoles', plural: 'clusterroles', apiVersion: 'v1', apiGroup: 'rbac.authorization.k8s.io', namespaced: false },
  ClusterRoleBinding: { abbr: 'crb', kind: 'ClusterRoleBinding', label: 'ClusterRoleBinding', labelPlural: 'ClusterRoleBindings', plural: 'clusterrolebindings', apiVersion: 'v1', apiGroup: 'rbac.authorization.k8s.io', namespaced: false },
};

const userModel: Model = {
  abbr: 'u', kind: 'User', label: 'User', labelPlural: 'Users', plural: 'users',
  apiVersion: 'v1', apiGroup: 'user.openshift.io', namespaced: false,
};

const ingressModel: Model = {
  abbr: 'i', kind: 'Ingress', label: 'Ingress', labelPlural: 'Ingresses', plural: 'ingresses',
  apiVersion: 'v1', apiGroup: 'config.openshift.io', namespaced: false,
};

const modelFor = (doc: K8sObj): Model => models[doc.kind];

const Overview: FC<{ ns: string; user: string }> = ({ ns, user }) => {
  const [sts, stsLoaded, stsErr] = useK8sWatchResource<K8sObj>({
    groupVersionKind: { group: 'apps', version: 'v1', kind: 'StatefulSet' },
    namespace: ns,
    name: 'openshell',
  });
  const [pods, podsLoaded, podsErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { version: 'v1', kind: 'Pod' },
    namespace: ns,
    isList: true,
  });
  const [routes, routesLoaded, routesErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'route.openshift.io', version: 'v1', kind: 'Route' },
    namespace: ns,
    isList: true,
  });
  const [sandboxes, sbLoaded, sbErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'agents.x-k8s.io', version: 'v1beta1', kind: 'Sandbox' },
    namespace: ns,
    isList: true,
  });
  const [roleBindings, rbLoaded, rbErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'rbac.authorization.k8s.io', version: 'v1', kind: 'RoleBinding' },
    namespace: ns,
    isList: true,
  });

  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const gwReady = stsLoaded ? (sts?.status?.readyReplicas ?? 0) : 0;
  const gwTotal = stsLoaded ? (sts?.spec?.replicas ?? 1) : 0;
  const deployed = stsLoaded && !!sts?.metadata?.name;
  const route = routesLoaded ? (routes ?? []).find((r) => r.metadata?.name === 'openshell') : null;
  const host = (route?.spec as { host?: string } | undefined)?.host ?? null;
  const gwPods = podsLoaded ? (pods ?? []).filter((p) => p.metadata?.name === 'openshell-0') : [];
  const rbs = rbLoaded ? (roleBindings ?? []).map((rb) => rb.metadata?.name ?? '') : [];

  const clusterDomain = async (): Promise<string> => {
    const ing = await k8sGet({ model: ingressModel, name: 'cluster' } as never);
    return ((ing as K8sObj)?.spec?.domain as string) ?? '';
  };

  const deploy = async () => {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      // 1. Namespace (auto-provisioning si el usuario puede crearlo; si no,
      // mensaje claro de provisioning).
      let nsExists = true;
      try {
        await k8sGet({ model: models.Namespace, name: ns } as never);
      } catch (e) {
        const s = String(e);
        if (s.includes('404') || s.toLowerCase().includes('not found')) {
          nsExists = false;
        } else {
          throw e;
        }
      }
      if (!nsExists) {
        try {
          await k8sCreate({ model: models.Namespace, data: { apiVersion: 'v1', kind: 'Namespace', metadata: { name: ns } } } as never);
        } catch {
          throw new Error(
            `Tu namespace ${ns} no existe y no puedes crearlo. Pide el provisioning a un admin con manifests/apply-openshell-users.sh (USERS=<tu usuario>)`,
          );
        }
      }
      // 2. RBAC por usuario (ClusterRole node-reader cluster-scoped + RoleBindings).
      // AlreadyExists o Forbidden se ignoran: para no-admins ya lo crea el
      // provisioning; para admins el plugin se auto-provisiona.
      const rbacDocs: K8sObj[] = JSON.parse(RBAC_JSON.split('__NS__').join(ns).split('__USER__').join(user));
      for (const doc of rbacDocs) {
        try {
          if (doc.kind === 'Role' || doc.kind === 'RoleBinding') {
            await k8sCreate({ model: modelFor(doc), data: doc, ns } as never);
          } else {
            await k8sCreate({ model: modelFor(doc), data: doc } as never);
          }
        } catch {
          // AlreadyExists / Forbidden: continúa
        }
      }
      // 3. Bundle del chart oficial (gateway + Route pública).
      const domain = await clusterDomain();
      const host = `openshell-${ns}.${domain}`;
      const docs: K8sObj[] = JSON.parse(BUNDLE_JSON.split('__NS__').join(ns).split('__HOST__').join(host));
      const ordered = docs.filter((d) => d.kind === 'Job').concat(docs.filter((d) => d.kind !== 'Job'));
      let created = 0;
      const fails: string[] = [];
      for (const doc of ordered) {
        try {
          await k8sCreate({ model: modelFor(doc), data: doc, ns } as never);
          created++;
        } catch (e) {
          const s = String(e);
          if (s.includes('409') || s.includes('AlreadyExists')) created++;
          else fails.push(`${doc.kind}/${doc.metadata?.name}: ${s.slice(0, 120)}`);
        }
      }
      setMsg(
        `Desplegado ${created}/${ordered.length} recursos en ${ns} (chart ${BUNDLE_CHART_VERSION}). ` +
          (fails.length ? `Fallos: ${fails.join(' | ')}` : 'El gateway arranca cuando el certgen genere los certs (~30s).'),
      );
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const domain = await clusterDomain();
      const host = `openshell-${ns}.${domain}`;
      const docs: K8sObj[] = JSON.parse(BUNDLE_JSON.split("__NS__").join(ns).split("__HOST__").join(host));
      for (const doc of docs.reverse()) {
        try {
          await k8sDelete({ model: modelFor(doc), resource: { metadata: { name: doc.metadata.name, namespace: ns } } } as never);
        } catch {
          // ignora: puede no existir
        }
      }
      setMsg(`OpenShell borrado de ${ns} (el PVC openshell-data con la DB se conserva; bórralo manualmente si quieres).`);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const restart = async () => {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      await k8sPatch({
        model: models.StatefulSet,
        resource: { metadata: { name: 'openshell', namespace: ns } },
        data: [{ op: 'add', path: '/spec/template/metadata/annotations', value: { 'kubectl.kubernetes.io/restartedAt': new Date().toISOString() } }],
      } as never);
      setMsg('Gateway reiniciando...');
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const errList = [stsErr, podsErr, routesErr, sbErr, rbErr].filter(Boolean);
  const isForbidden = errList.some((e) => String(e).includes('403') || String(e).toLowerCase().includes('forbidden'));

  return (
    <>
      {(errList.length > 0) && (
        <Alert variant={isForbidden ? 'info' : 'warning'} isInline title={isForbidden ? `Sin acceso a ${ns}` : 'Error leyendo recursos'}>
          {isForbidden ? (
            <div>
              Tu namespace es <code>{ns}</code> y aún no existe o no tienes permisos. Pide el provisioning con{' '}
              <code>manifests/apply-openshell-users.sh</code> o despliega primero (crea el namespace requiere admin).
            </div>
          ) : (
            errList.map((e, i) => <div key={i}>{String(e).slice(0, 200)}</div>)
          )}
        </Alert>
      )}
      <PageSection>
        <Split hasGutter>
          <SplitItem isFilled>
            <Title headingLevel="h2">Gateway OpenShell</Title>
            {stsLoaded && deployed ? (
              <p>
                Estado: <Label color={gwReady >= gwTotal ? 'green' : 'orange'} icon={gwReady >= gwTotal ? <CheckCircleIcon /> : <ExclamationCircleIcon />}>{gwReady}/{gwTotal} ready</Label>{' '}
                chart <code>{sts?.metadata?.labels?.['helm.sh/chart'] ?? BUNDLE_CHART_VERSION}</code>
              </p>
            ) : (
              <p>Sin gateway en <code>{ns}</code>.</p>
            )}
          </SplitItem>
          <SplitItem>
            {!deployed ? (
              <Button variant="primary" onClick={deploy} isDisabled={busy}>Desplegar mi OpenShell</Button>
            ) : (
              <Split hasGutter>
                <SplitItem><Button variant="secondary" onClick={restart} isDisabled={busy}>Reiniciar</Button></SplitItem>
                <SplitItem><Button variant="danger" onClick={remove} isDisabled={busy}>Borrar mi OpenShell</Button></SplitItem>
              </Split>
            )}
          </SplitItem>
        </Split>
        {msg && <Alert variant="info" isInline title={msg} />}
        {err && <Alert variant="danger" isInline title={err} />}
        {host && (
          <p>
            Link público: <a href={`https://${host}`} target="_blank" rel="noopener">{host} <ExternalLinkAltIcon /></a>{' '}
            (TLS passthrough + mTLS; el CLI conecta con <code>openshell gateway add https://{host} --name {ns}</code> y el bundle del secret <code>openshell-client-tls</code>).
          </p>
        )}
      </PageSection>
      <PageSection>
        <Title headingLevel="h3">Pods</Title>
        {!podsLoaded ? (
          <Spinner size="md" />
        ) : (
          <Table aria-label="Pods OpenShell">
            <Thead>
              <Tr><Th>Nombre</Th><Th>Estado</Th><Th>Restarts</Th></Tr>
            </Thead>
            <Tbody>
              {(gwPods.length > 0 ? gwPods : []).map((p) => (
                <Tr key={p.metadata?.name}>
                  <Td>{p.metadata?.name}</Td>
                  <Td>{p.status?.phase}</Td>
                  <Td>{p.status?.containerStatuses?.[0]?.restartCount ?? 0}</Td>
                </Tr>
              ))}
              {gwPods.length === 0 && (
                <Tr><Td colSpan={3}>Sin pods del gateway.</Td></Tr>
              )}
            </Tbody>
          </Table>
        )}
      </PageSection>
      <PageSection>
        <Title headingLevel="h3">Sandboxes</Title>
        {!sbLoaded ? (
          <Spinner size="md" />
        ) : (sandboxes ?? []).length === 0 ? (
          <EmptyState titleText="Sin sandboxes">
            <EmptyStateBody>
              Crea sandboxes con el CLI: <code>openshell sandbox run --gateway {ns} ...</code> (módulo 23.1).
            </EmptyStateBody>
          </EmptyState>
        ) : (
          <Table aria-label="Sandboxes">
            <Thead>
              <Tr><Th>Nombre</Th><Th>Estado</Th><Th>Edad</Th></Tr>
            </Thead>
            <Tbody>
              {(sandboxes ?? []).map((sb) => (
                <Tr key={sb.metadata?.name}>
                  <Td>{sb.metadata?.name}</Td>
                  <Td>{sb.status?.phase ?? sb.status?.state ?? '-'}</Td>
                  <Td>{sb.metadata?.creationTimestamp}</Td>
                </Tr>
              ))}
            </Tbody>
          </Table>
        )}
      </PageSection>
      <PageSection>
        <Title headingLevel="h3">Mis permisos (RoleBindings)</Title>
        {!rbLoaded ? (
          <Spinner size="md" />
        ) : rbs.length === 0 ? (
          <p>Sin RoleBindings en <code>{ns}</code>.</p>
        ) : (
          <p>{rbs.map((r) => <Label key={r} isCompact style={{ marginRight: 8 }}>{r}</Label>)}</p>
        )}
      </PageSection>
    </>
  );
};

const OpenShellPage: FC = () => {
  const [user, setUser] = useState<string | null>(null);
  const [userErr, setUserErr] = useState<string | null>(null);

  useEffect(() => {
    k8sGet({ model: userModel, name: '~' } as never)
      .then((u: K8sObj) => setUser(u?.metadata?.name ?? null))
      .catch((e: unknown) => setUserErr(String(e)));
  }, []);

  return (
    <>
      <DocumentTitle>OpenShell - Manager</DocumentTitle>
      <PageSection>
        <Title headingLevel="h1">OpenShell - Manager</Title>
        <p>
          Tu OpenShell en tu namespace: gateway con Route pública, sandboxes y permisos.
          Provisioning inicial (namespace + RBAC) con <code>manifests/apply-openshell-users.sh</code>.
        </p>
      </PageSection>
      {userErr ? (
        <PageSection>
          <Alert variant="danger" isInline title="No se pudo leer el usuario actual">
            {userErr.slice(0, 200)}
          </Alert>
        </PageSection>
      ) : !user ? (
        <PageSection><Spinner size="lg" /></PageSection>
      ) : (
        <Overview ns={`openshell-${user}`} user={user} />
      )}
    </>
  );
};

export default OpenShellPage;
