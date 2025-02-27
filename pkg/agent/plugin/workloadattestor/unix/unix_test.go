package unix

import (
	"context"
	"fmt"
	"io/ioutil"
	"os/user"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/sirupsen/logrus"
	"github.com/sirupsen/logrus/hooks/test"
	"github.com/spiffe/spire/pkg/common/telemetry"
	workloadattestorv0 "github.com/spiffe/spire/proto/spire/agent/workloadattestor/v0"
	spi "github.com/spiffe/spire/proto/spire/common/plugin"
	"github.com/spiffe/spire/test/spiretest"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
)

var (
	ctx = context.Background()
)

func TestPlugin(t *testing.T) {
	spiretest.Run(t, new(Suite))
}

type Suite struct {
	spiretest.Suite

	dir     string
	p       workloadattestorv0.Plugin
	logHook *test.Hook
}

func (s *Suite) SetupTest() {
	s.dir = s.TempDir()

	p := New()
	p.hooks.newProcess = func(pid int32) (processInfo, error) {
		return newFakeProcess(pid, s.dir), nil
	}
	p.hooks.lookupUserByID = fakeLookupUserByID
	p.hooks.lookupGroupByID = fakeLookupGroupByID
	log, hook := test.NewNullLogger()
	s.logHook = hook
	s.LoadPlugin(builtin(p), &s.p, spiretest.Logger(log))

	s.configure("")
}

func (s *Suite) TestAttest() {
	testCases := []struct {
		name         string
		pid          int32
		err          string
		selectors    []string
		config       string
		expectedLogs []spiretest.LogEntry
	}{
		{
			name: "pid with no uids",
			pid:  1,
			err:  "unix: UIDs lookup: no UIDs for process",
		},
		{
			name: "fail to get uids",
			pid:  2,
			err:  "unix: UIDs lookup: unable to get UIDs for PID 2",
		},
		{
			name: "user lookup fails",
			pid:  3,
			selectors: []string{
				"uid:1999",
				"gid:2000",
				"group:g2000",
			},
			expectedLogs: []spiretest.LogEntry{
				{
					Level:   logrus.WarnLevel,
					Message: "Failed to lookup user name by uid",
					Data: logrus.Fields{
						"uid":                   "1999",
						logrus.ErrorKey:         "no user with UID 1999",
						telemetry.SubsystemName: "built-in_plugin.unix",
					},
				},
			},
		},
		{
			name: "pid with no gids",
			pid:  4,
			err:  "unix: GIDs lookup: no GIDs for process",
		},
		{
			name: "fail to get gids",
			pid:  5,
			err:  "unix: GIDs lookup: unable to get GIDs for PID 5",
		},
		{
			name: "group lookup fails",
			pid:  6,
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2999",
			},
			expectedLogs: []spiretest.LogEntry{
				{
					Level:   logrus.WarnLevel,
					Message: "Failed to lookup group name by gid",
					Data: logrus.Fields{
						"gid":                   "2999",
						logrus.ErrorKey:         "no group with GID 2999",
						telemetry.SubsystemName: "built-in_plugin.unix",
					},
				},
			},
		},
		{
			name: "primary user and gid",
			pid:  7,
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2000",
				"group:g2000",
			},
		},
		{
			name: "effective user and gid",
			pid:  8,
			selectors: []string{
				"uid:1100",
				"user:u1100",
				"gid:2100",
				"group:g2100",
			},
		},
		{
			name:   "fail to get process binary path",
			pid:    9,
			config: "discover_workload_path = true",
			err:    "unix: path lookup: unable to get EXE for PID 9",
		},
		{
			name:   "fail to hash process binary",
			pid:    10,
			config: "discover_workload_path = true",
			err:    "unix: SHA256 digest: open /proc/10/unreadable-exe: no such file or directory",
		},
		{
			name:   "process binary exceeds size limits",
			pid:    11,
			config: "discover_workload_path = true\nworkload_size_limit = 2",
			err:    fmt.Sprintf("unix: SHA256 digest: workload %s exceeds size limit (4 > 2)", filepath.Join(s.dir, "exe")),
		},
		{
			name:   "success getting path and hashing process binary",
			pid:    12,
			config: "discover_workload_path = true",
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2000",
				"group:g2000",
				fmt.Sprintf("path:%s", filepath.Join(s.dir, "exe")),
				"sha256:3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
			},
		},
		{
			name:   "success getting path and hashing process binary",
			pid:    12,
			config: "discover_workload_path = true",
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2000",
				"group:g2000",
				fmt.Sprintf("path:%s", filepath.Join(s.dir, "exe")),
				"sha256:3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
			},
		},
		{
			name:   "success getting path, disabled hashing process binary",
			pid:    12,
			config: "discover_workload_path = true\nworkload_size_limit = -1",
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2000",
				"group:g2000",
				fmt.Sprintf("path:%s", filepath.Join(s.dir, "exe")),
			},
		},
		{
			name: "pid with supplementary gids",
			pid:  13,
			selectors: []string{
				"uid:1000",
				"user:u1000",
				"gid:2000",
				"group:g2000",
				"supplementary_gid:2000",
				"supplementary_group:g2000",
				"supplementary_gid:2100",
				"supplementary_group:g2100",
				"supplementary_gid:2200",
				"supplementary_group:g2200",
				"supplementary_gid:2300",
				"supplementary_group:g2300",
			},
		},
		{
			name: "fail to get supplementary gids",
			pid:  14,
			err:  "unix: supplementary GIDs lookup: some error for PID 14",
		},
	}

	// prepare the "exe" for hashing
	s.writeFile("exe", []byte("data"))

	for _, testCase := range testCases {
		testCase := testCase
		s.T().Run(testCase.name, func(t *testing.T) {
			defer s.logHook.Reset()
			s.configure(testCase.config)
			resp, err := s.p.Attest(ctx, &workloadattestorv0.AttestRequest{
				Pid: testCase.pid,
			})

			if testCase.err != "" {
				spiretest.RequireGRPCStatus(t, err, codes.Unknown, testCase.err)
				require.Nil(t, resp)
				return
			}

			require.NoError(t, err)
			require.NotNil(t, resp)
			var selectors []string
			for _, selector := range resp.Selectors {
				require.Equal(t, "unix", selector.Type)
				selectors = append(selectors, selector.Value)
			}

			require.Equal(t, testCase.selectors, selectors)
			spiretest.AssertLogs(t, s.logHook.AllEntries(), testCase.expectedLogs)
		})
	}
}

func (s *Suite) TestConfigure() {
	resp, err := s.p.Configure(ctx, &spi.ConfigureRequest{})
	s.NoError(err)
	s.AssertProtoEqual(&spi.ConfigureResponse{}, resp)
}

func (s *Suite) TestGetPluginInfo() {
	resp, e := s.p.GetPluginInfo(ctx, &spi.GetPluginInfoRequest{})
	s.NoError(e)
	s.AssertProtoEqual(&spi.GetPluginInfoResponse{}, resp)
}

func (s *Suite) configure(config string) {
	_, err := s.p.Configure(ctx, &spi.ConfigureRequest{
		Configuration: config,
	})
	s.Require().NoError(err)
}

func (s *Suite) writeFile(path string, data []byte) {
	s.Require().NoError(ioutil.WriteFile(filepath.Join(s.dir, path), data, 0600))
}

type fakeProcess struct {
	pid int32
	dir string
}

func (p fakeProcess) Uids() ([]int32, error) {
	switch p.pid {
	case 1:
		return []int32{}, nil
	case 2:
		return nil, fmt.Errorf("unable to get UIDs for PID %d", p.pid)
	case 3:
		return []int32{1999}, nil
	case 4, 5, 6, 7, 9, 10, 11, 12, 13, 14:
		return []int32{1000}, nil
	case 8:
		return []int32{1000, 1100}, nil
	default:
		return nil, fmt.Errorf("unhandled uid test case %d", p.pid)
	}
}

func (p fakeProcess) Gids() ([]int32, error) {
	switch p.pid {
	case 4:
		return []int32{}, nil
	case 5:
		return nil, fmt.Errorf("unable to get GIDs for PID %d", p.pid)
	case 6:
		return []int32{2999}, nil
	case 3, 7, 9, 10, 11, 12, 13, 14:
		return []int32{2000}, nil
	case 8:
		return []int32{2000, 2100}, nil
	default:
		return nil, fmt.Errorf("unhandled gid test case %d", p.pid)
	}
}

func (p fakeProcess) Groups() ([]string, error) {
	switch p.pid {
	case 13:
		return []string{"2000", "2100", "2200", "2300"}, nil
	case 14:
		return nil, fmt.Errorf("some error for PID %d", p.pid)
	default:
		return []string{}, nil
	}
}

func (p fakeProcess) Exe() (string, error) {
	switch p.pid {
	case 7, 8, 9:
		return "", fmt.Errorf("unable to get EXE for PID %d", p.pid)
	case 10:
		return filepath.Join(p.dir, "unreadable-exe"), nil
	case 11, 12:
		return filepath.Join(p.dir, "exe"), nil
	default:
		return "", fmt.Errorf("unhandled exe test case %d", p.pid)
	}
}

func (p fakeProcess) NamespacedExe() string {
	switch p.pid {
	case 11, 12:
		return filepath.Join(p.dir, "exe")
	default:
		return filepath.Join("/proc", strconv.Itoa(int(p.pid)), "unreadable-exe")
	}
}

func newFakeProcess(pid int32, dir string) processInfo {
	return fakeProcess{pid: pid, dir: dir}
}

func fakeLookupUserByID(uid string) (*user.User, error) {
	switch uid {
	case "1000":
		return &user.User{Username: "u1000"}, nil
	case "1100":
		return &user.User{Username: "u1100"}, nil
	default:
		return nil, fmt.Errorf("no user with UID %s", uid)
	}
}

func fakeLookupGroupByID(gid string) (*user.Group, error) {
	switch gid {
	case "2000":
		return &user.Group{Name: "g2000"}, nil
	case "2100":
		return &user.Group{Name: "g2100"}, nil
	case "2200":
		return &user.Group{Name: "g2200"}, nil
	case "2300":
		return &user.Group{Name: "g2300"}, nil
	default:
		return nil, fmt.Errorf("no group with GID %s", gid)
	}
}
