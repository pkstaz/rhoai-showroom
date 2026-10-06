import {
  DocumentTitle,
  useK8sWatchResource,
  k8sCreate,
  k8sGet,
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
  Modal,
  Form,
  FormGroup,
  TextInput,
  Alert,
  HelperText,
  HelperTextItem,
} from '@patternfly/react-core';
import { Table, Thead, Tbody, Tr, Th, Td } from '@patternfly/react-table';
import {
  KeyIcon,
  CheckCircleIcon,
  ExclamationCircleIcon,
  ExternalLinkAltIcon,
} from '@patternfly/react-icons';
import type { FC } from 'react';
import { useState } from 'react';

const NS = 'opencode-users';
const APP_LABEL = 'opencode-agent';

type K8sObj = {
  metadata?: { name?: string; labels?: Record<string, string> };
  status?: { readyReplicas?: number };
  spec?: { replicas?: number; host?: string };
};

const secretModel = {
  abbr: 's',
  kind: 'Secret',
  label: 'Secret',
  labelPlural: 'Secrets',
  plural: 'secrets',
  apiVersion: 'v1',
  namespaced: true,
};

const deployModel = {
  abbr: 'd',
  kind: 'Deployment',
  label: 'Deployment',
  labelPlural: 'Deployments',
  plural: 'deployments',
  apiVersion: 'v1',
  apiGroup: 'apps',
  namespaced: true,
};

type ModalState = {
  user: string | null;
  key: string;
  saving: boolean;
  msg: string | null;
  err: string | null;
};

const AgentsPage: FC = () => {
  const [deps, depsLoaded, depsErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'apps', version: 'v1', kind: 'Deployment' },
    namespace: NS,
    isList: true,
  });
  const [routes, routesLoaded, routesErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { group: 'route.openshift.io', version: 'v1', kind: 'Route' },
    namespace: NS,
    isList: true,
  });
  const [secrets, secretsLoaded, secretsErr] = useK8sWatchResource<K8sObj[]>({
    groupVersionKind: { version: 'v1', kind: 'Secret' },
    namespace: NS,
    isList: true,
  });

  const [modal, setModal] = useState<ModalState>({
    user: null,
    key: '',
    saving: false,
    msg: null,
    err: null,
  });

  const agents = (depsLoaded ? (deps ?? []) : []).filter(
    (d) => d.metadata?.labels?.app === APP_LABEL,
  );

  const depStatus = (d: K8sObj) => {
    const ready = d.status?.readyReplicas ?? 0;
    const total = d.spec?.replicas ?? 1;
    return { ready, total, text: `${ready}/${total}` };
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

  const saveKey = async () => {
    const user = modal.user;
    if (!user || !modal.key) return;
    setModal((m) => ({ ...m, saving: true, msg: null, err: null }));
    const secretName = `opencode-maas-key-${user}`;
    try {
      let exists = true;
      try {
        await k8sGet({ model: secretModel, name: secretName, ns: NS } as never);
      } catch {
        exists = false;
      }
      if (!exists) {
        await k8sCreate({
          model: secretModel,
          data: {
            metadata: { name: secretName, namespace: NS },
            stringData: { MAAS_API_KEY: modal.key },
          },
        } as never);
      } else {
        await k8sPatch({
          model: secretModel,
          resource: { metadata: { name: secretName, namespace: NS } },
          data: [{ op: 'add', path: '/stringData', value: { MAAS_API_KEY: modal.key } }],
        } as never);
      }
      await k8sPatch({
        model: deployModel,
        resource: { metadata: { name: `opencode-${user}`, namespace: NS } },
        data: [
          {
            op: 'add',
            path: '/spec/template/metadata/annotations',
            value: { 'kubectl.kubernetes.io/restartedAt': new Date().toISOString() },
          },
        ],
      } as never);
      setModal((m) => ({
        ...m,
        saving: false,
        msg: `API key guardada en el secret ${secretName}; reiniciando el agente...`,
        key: '',
      }));
    } catch (e) {
      setModal((m) => ({ ...m, saving: false, err: String(e) }));
    }
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
        {(routesErr || secretsErr || depsErr) && (
          <Alert
            variant="warning"
            isInline
            title="Error leyendo recursos del cluster (¿permisos insuficientes?)"
          >
            {[depsErr, routesErr, secretsErr].filter(Boolean).map((e, i) => (
              <div key={i}>{String(e).slice(0, 200)}</div>
            ))}
          </Alert>
        )}
        {!depsLoaded ? (
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
                <Th>Acciones</Th>
              </Tr>
            </Thead>
            <Tbody>
              {agents.map((d) => {
                const user = d.metadata?.labels?.user ?? d.metadata?.name ?? '';
                const st = depStatus(d);
                const host = routeHost(user);
                const key = hasKey(user);
                return (
                  <Tr key={d.metadata?.name}>
                    <Td>{user}</Td>
                    <Td>
                      <Label
                        color={st.ready === st.total ? 'green' : 'red'}
                        icon={
                          st.ready === st.total ? (
                            <CheckCircleIcon />
                          ) : (
                            <ExclamationCircleIcon />
                          )
                        }
                      >
                        {st.text}
                      </Label>
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
                    <Td>
                      <Button
                        variant="secondary"
                        icon={<KeyIcon />}
                        onClick={() =>
                          setModal({ user, key: '', saving: false, msg: null, err: null })
                        }
                      >
                        Configurar key
                      </Button>
                    </Td>
                  </Tr>
                );
              })}
            </Tbody>
          </Table>
        )}
      </PageSection>
      <Modal
        title={`API key MaaS - ${modal.user ?? ''}`}
        isOpen={modal.user !== null}
        onClose={() => setModal({ user: null, key: '', saving: false, msg: null, err: null })}
      >
        <Form>
          {modal.msg && <Alert variant="success" isInline title={modal.msg} />}
          {modal.err && <Alert variant="danger" isInline title="Error al guardar la key">
            {modal.err.slice(0, 200)}
          </Alert>}
          <FormGroup label="API key" fieldId="api-key">
            <TextInput
              id="api-key"
              type="password"
              value={modal.key}
              onChange={(_, v) => setModal((m) => ({ ...m, key: v }))}
              placeholder="sk-oai-..."
            />
            <HelperText>
              <HelperTextItem>
                Key de MaaS del usuario (sk-oai-...). Se guarda en el secret
                opencode-maas-key-&lt;user&gt; y el agente se reinicia para usarla.
              </HelperTextItem>
            </HelperText>
          </FormGroup>
          <Button
            variant="primary"
            onClick={saveKey}
            isDisabled={!modal.key || modal.saving}
            isLoading={modal.saving}
          >
            Guardar y reiniciar agente
          </Button>
        </Form>
      </Modal>
    </>
  );
};

export default AgentsPage;
